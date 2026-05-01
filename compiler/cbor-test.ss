;;; cbor-test.ss --- unit tests for the CBOR encoder
;;;
;;; Run with:
;;;   chez --libdirs compiler --script compiler/cbor-test.ss
;;;
;;; Encodes Scheme datums via (cbor)::print-cbor and asserts the output
;;; bytes match RFC 8949 Appendix A test vectors hex-for-hex, plus
;;; project-specific shapes (alist-as-map, mixed structures).

#!chezscheme

(import (chezscheme) (cbor))

(define failures 0)

(define (bv->hex bv)
  (let ([n (bytevector-length bv)]
        [out (open-output-string)])
    (do ([i 0 (+ i 1)])
        ((= i n) (get-output-string out))
      (fprintf out "~(~2,'0x~)" (bytevector-u8-ref bv i)))))

(define (encode datum)
  (let-values ([(op extract) (open-bytevector-output-port)])
    (print-cbor op datum)
    (extract)))

(define (check label datum expected-hex)
  (let* ([got-hex (bv->hex (encode datum))])
    (if (string=? got-hex expected-hex)
        (printf "ok  ~a~n" label)
        (begin
          (set! failures (+ failures 1))
          (printf "FAIL ~a~n  expected: ~a~n  got:      ~a~n"
                  label expected-hex got-hex)))))

;; -- Unsigned ints (RFC 8949 Appendix A) ------------------------------
(check "uint 0"            0           "00")
(check "uint 1"            1           "01")
(check "uint 10"           10          "0a")
(check "uint 23"           23          "17")
(check "uint 24"           24          "1818")
(check "uint 25"           25          "1819")
(check "uint 100"          100         "1864")
(check "uint 255"          255         "18ff")
(check "uint 256"          256         "190100")
(check "uint 1000"         1000        "1903e8")
(check "uint 65535"        65535       "19ffff")
(check "uint 65536"        65536       "1a00010000")
(check "uint 1000000"      1000000     "1a000f4240")
(check "uint 4294967295"   4294967295  "1affffffff")
(check "uint 4294967296"   4294967296  "1b0000000100000000")
(check "uint 1000000000000" 1000000000000 "1b000000e8d4a51000")
(check "uint u64-max"      18446744073709551615 "1bffffffffffffffff")

;; -- Negative ints ----------------------------------------------------
(check "nint -1"           -1          "20")
(check "nint -10"          -10         "29")
(check "nint -23"          -23         "36")
(check "nint -24"          -24         "37")
(check "nint -25"          -25         "3818")
(check "nint -100"         -100        "3863")
(check "nint -256"         -256        "38ff")
(check "nint -257"         -257        "390100")
(check "nint -1000"        -1000       "3903e7")
(check "nint -65536"       -65536      "39ffff")
(check "nint -65537"       -65537      "3a00010000")
(check "nint -2^32"        -4294967296 "3affffffff")
(check "nint -2^32-1"      -4294967297 "3b0000000100000000")

;; -- Bignum text-string fallback (>u64, <-2^64) -----------------------
;; RFC 8949 Appendix A uses tag 2/3 for native bignums; we instead emit
;; a CBOR text string carrying the decimal representation, matching the
;; IntLit::visit_str fallback path that already exists in the consumer.
(check "bignum u64+1"
       18446744073709551616
       ;; tstr of "18446744073709551616" (20 bytes) -- head 0x74 + utf8
       (string-append "74" "3138343436373434303733373039353531363136"))
(check "bignum -u64-1"
       -18446744073709551617
       (string-append "75"
                      "2d3138343436373434303733373039353531363137"))

;; -- Strings ----------------------------------------------------------
(check "tstr empty"        ""          "60")
(check "tstr 'a'"          "a"         "6161")
(check "tstr 'IETF'"       "IETF"      "6449455446")
(check "tstr quote+bs"     "\"\\"      "62225c")
(check "symbol 'foo'"      'foo        "63666f6f")

;; -- Booleans, null ---------------------------------------------------
(check "false"             #f          "f4")
(check "true"              #t          "f5")
(check "null"              (void)      "f6")

;; -- Arrays -----------------------------------------------------------
(check "array empty"       (vector)               "80")
(check "array [1,2,3]"     (vector 1 2 3)         "83010203")
(check "array nested"      (vector 1 (vector 2 3) (vector 4 5))
       "8301820203820405")
(check "array of 25"
       (let loop ([n 25] [acc '()])
         (if (= n 0) (list->vector acc) (loop (- n 1) (cons n acc))))
       "98190102030405060708090a0b0c0d0e0f101112131415161718181819")

;; -- Maps (alists) ----------------------------------------------------
(check "map empty"         '()                                "a0")
(check "map {1:2,3:4}"     '((1 . 2) (3 . 4))                 "a201020304")
(check "map {a:1,b:[2,3]}" `(("a" . 1) ("b" . ,(vector 2 3))) "a26161016162820203")
(check "array [a,{b:c}]"
       (vector "a" '(("b" . "c")))
       "826161a161626163")

;; -- Project-shape sanity (mirrors runtime-ir-passes.ss output) ------
(check "type-name Boolean shape"
       '(("type-name" . "Boolean"))
       (string-append "a1" "69" "747970652d6e616d65" "67" "426f6f6c65616e"))

;; -- Final report -----------------------------------------------------
(if (zero? failures)
    (begin
      (printf "~nall tests passed~n")
      (exit 0))
    (begin
      (printf "~n~d failure(s)~n" failures)
      (exit 1)))
