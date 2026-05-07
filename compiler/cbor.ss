;;; cbor.ss --- CBOR (RFC 8949) encoder for Compact runtime IR
;;;
;;; This file is part of Compact.
;;; Copyright (C) 2025 Midnight Foundation
;;; SPDX-License-Identifier: Apache-2.0
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;; 	http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.
;;;
;;; Concentric Scheme datum convention (mirrors json.ss):
;;;   alist of (key . value) pairs   -> CBOR map (major type 5)
;;;   vector                         -> CBOR array (major type 4)
;;;   bytevector                     -> CBOR byte string (major type 2)
;;;   string                         -> CBOR text string (major type 3)
;;;   symbol                         -> CBOR text string (symbol->string)
;;;   exact integer in [-2^64, 2^64) -> CBOR uint or nint (major 0/1)
;;;   exact integer outside u64/i64  -> CBOR text string (decimal)
;;;                                     consumers parse via IntLit::visit_str
;;;   #t / #f                        -> simple true/false (major 7, 21/20)
;;;   (void)                         -> simple null (major 7, 22)
;;;
;;; Output port must be a binary output port; this encoder writes raw
;;; bytes via put-u8 / put-bytevector.

#!chezscheme

(library (cbor)
  (export print-cbor)
  (import (except (chezscheme) errorf)
          (utils))

  ;; Major types (upper 3 bits of the initial byte).
  (define MT-UINT   0)
  (define MT-NINT   1)
  (define MT-BSTR   2)
  (define MT-TSTR   3)
  (define MT-ARRAY  4)
  (define MT-MAP    5)
  (define MT-SIMPLE 7)

  ;; Simple values (major 7 immediates).
  (define SIMPLE-FALSE 20)
  (define SIMPLE-TRUE  21)
  (define SIMPLE-NULL  22)

  ;; Range gates.
  (define UINT64-MAX (- (expt 2 64) 1))
  (define NINT-MIN   (- (expt 2 64)))   ; smallest representable CBOR nint

  ;; Write `n` as `bytes` big-endian octets.
  (define (put-be op n bytes)
    (let loop ([i (- bytes 1)])
      (when (>= i 0)
        (put-u8 op (bitwise-and (bitwise-arithmetic-shift-right n (* i 8)) #xff))
        (loop (- i 1)))))

  ;; Emit a CBOR head: major type in upper 3 bits + argument.
  ;;   0..23  -> argument inline in lower 5 bits
  ;;   24     -> 1-byte argument follows
  ;;   25     -> 2-byte argument follows
  ;;   26     -> 4-byte argument follows
  ;;   27     -> 8-byte argument follows
  (define (put-head op major arg)
    (unless (and (integer? arg) (>= arg 0))
      (internal-errorf 'put-head "argument must be non-negative integer, got ~s" arg))
    (let ([mt5 (bitwise-arithmetic-shift-left major 5)])
      (cond
        [(< arg 24)
         (put-u8 op (bitwise-ior mt5 arg))]
        [(< arg 256)
         (put-u8 op (bitwise-ior mt5 24))
         (put-u8 op arg)]
        [(< arg 65536)
         (put-u8 op (bitwise-ior mt5 25))
         (put-be op arg 2)]
        [(< arg (expt 2 32))
         (put-u8 op (bitwise-ior mt5 26))
         (put-be op arg 4)]
        [(<= arg UINT64-MAX)
         (put-u8 op (bitwise-ior mt5 27))
         (put-be op arg 8)]
        [else
         (internal-errorf 'put-head "argument ~s exceeds u64 max" arg)])))

  (define (encode-uint op n) (put-head op MT-UINT n))

  ;; CBOR negative-int wire value is (-1 - n); must fit in a u64.
  (define (encode-nint op n) (put-head op MT-NINT (- -1 n)))

  (define (encode-tstr op s)
    (let* ([bv (string->utf8 s)]
           [len (bytevector-length bv)])
      (put-head op MT-TSTR len)
      (put-bytevector op bv)))

  (define (encode-bstr op bv)
    (let ([len (bytevector-length bv)])
      (put-head op MT-BSTR len)
      (put-bytevector op bv)))

  (define (encode-int op n)
    (cond
      [(>= n 0)
       (if (<= n UINT64-MAX)
           (encode-uint op n)
           ;; >u64 -- emit as decimal text string. Consumers resolve via
           ;; IntLit::visit_str (see crates/runtime-ir/src/ir.rs).
           (encode-tstr op (number->string n)))]
      [else
       (if (>= n NINT-MIN)
           (encode-nint op n)
           (encode-tstr op (number->string n)))]))

  (define (encode-simple op simple-val)
    (put-u8 op (bitwise-ior (bitwise-arithmetic-shift-left MT-SIMPLE 5) simple-val)))

  (define (encode-bool op b)
    (encode-simple op (if b SIMPLE-TRUE SIMPLE-FALSE)))

  (define (encode-null op)
    (encode-simple op SIMPLE-NULL))

  (define (encode-array op v)
    (let ([n (vector-length v)])
      (put-head op MT-ARRAY n)
      (let loop ([i 0])
        (unless (= i n)
          (encode-value op (vector-ref v i))
          (loop (+ i 1))))))

  (define (encode-map op alist)
    (put-head op MT-MAP (length alist))
    (for-each
      (lambda (pair)
        (encode-value op (car pair))
        (encode-value op (cdr pair)))
      alist))

  (define (encode-value op v)
    (cond
      [(eq? v (void))                     (encode-null op)]
      [(boolean? v)                       (encode-bool op v)]
      [(symbol? v)                        (encode-tstr op (symbol->string v))]
      [(string? v)                        (encode-tstr op v)]
      [(bytevector? v)                    (encode-bstr op v)]
      [(and (integer? v) (exact? v))      (encode-int op v)]
      [(vector? v)                        (encode-array op v)]
      ;; Match json.ss convention: non-empty list of pairs OR empty list
      ;; -> CBOR map.  (Empty list is treated as empty map, matching the
      ;; existing JSON path.)  Pure data lists are not produced by
      ;; runtime-ir-passes.ss; if encountered, error explicitly.
      [(and (list? v) (andmap pair? v))   (encode-map op v)]
      [else
       (internal-errorf 'print-cbor "unexpected datum ~s" v)]))

  (define (print-cbor op v)
    (encode-value op v))
)
