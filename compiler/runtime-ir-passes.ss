#!chezscheme

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

;;; runtime-ir-passes.ss --- emit a language-agnostic JSON IR
;;;
;;; This pass walks the post-typescript-prep IR (`Ltypescript`) and emits a
;;; structured JSON file at `compiler/runtime-ir.json` describing every
;;; runtime-affecting construct of the contract.  See `doc/runtime-ir.md`
;;; for the schema specification.
;;;
;;; The pass runs after `prepare-for-typescript` (which produces
;;; `Ltypescript`) so we get the same lowered IR the JS emitter consumes.
;;; The IR file is additive: `contract-info.json` is unchanged.
;;;
;;; The pass hard-errors on any analyzed-IR construct it cannot serialize,
;;; per the project's no-silent-partials discipline.

(library (runtime-ir-passes)
  (export runtime-ir-passes)
  (import (except (chezscheme) errorf)
          (utils)
          (datatype)
          (nanopass)
          (json)
          (langs)
          (vm)
          (compiler-version)
          (language-version)
          (runtime-version)
          (typescript-passes)
          (pass-helpers))

  (define schema-version 1)

  ;; A ref-expression carrier: when expand-vm-code substitutes an arg
  ;; (e.g. circuit-call argument or runtime-computed path element), we
  ;; pass through a `vmref-expr` record carrying the type + the IR-JSON
  ;; rendering of the underlying expression.  vmop->json recognises
  ;; this and emits a JSON node `{"vm": "ref", "type": ..., "value": <expr>}`.
  (define-record-type vmref-expr
    (nongenerative)
    (fields type expr-json))

  ;; Render an integer or big-integer as a JSON-safe representation.
  ;; Standard JSON `number` caps at 2^53; we use strings for anything
  ;; that exceeds the safe-integer range, matching the convention used
  ;; by `contract-info.json`'s `maxval`.
  (define safe-integer-max (expt 2 53))
  (define (number->json n)
    (cond
      [(not (integer? n)) n]
      [(and (>= n (- safe-integer-max)) (< n safe-integer-max)) n]
      [else (number->string n)]))

  ;; Convert a Scheme symbol to a JSON string.  All symbols in the IR
  ;; render as strings.
  (define (sym->json s)
    (if (symbol? s) (symbol->string s) s))

  ;; ------------------------------------------------------------------
  ;; Type rendering — mirrors save-contract-info-passes.ss::Type so the
  ;; runtime-ir.json's type shapes match contract-info.json bit-for-bit.
  ;; ------------------------------------------------------------------

  (define (clean-adt-name adt-name)
    (let ([s (symbol->string adt-name)])
      (if (string-prefix? "__compact_" s)
          (string->symbol (substring s 10 (string-length s)))
          adt-name)))

  ;; A non-emit pass that renders an Ltypescript Type as JSON.  We do
  ;; this with a `nanopass-case` walker rather than a define-pass since
  ;; the output is a Scheme datum, not an IR.
  (define (type->json type)
    (nanopass-case (Ltypescript Type) type
      [(tboolean ,src)
       '(("type-name" . "Boolean"))]
      [(tfield ,src)
       '(("type-name" . "Field"))]
      [(tunsigned ,src ,nat)
       (list (cons "type-name" "Uint")
             (cons "maxval" (number->json nat)))]
      [(tbytes ,src ,len)
       (list (cons "type-name" "Bytes")
             (cons "length" len))]
      [(topaque ,src ,opaque-type)
       (list (cons "type-name" "Opaque")
             (cons "tsType" opaque-type))]
      [(tvector ,src ,len ,type)
       (list (cons "type-name" "Vector")
             (cons "length" len)
             (cons "type" (type->json type)))]
      [(ttuple ,src ,type* ...)
       (list (cons "type-name" "Tuple")
             (cons "types" (list->vector (map type->json type*))))]
      [(tstruct ,src ,struct-name (,elt-name* ,type*) ...)
       (list (cons "type-name" "Struct")
             (cons "name" (sym->json struct-name))
             (cons "elements"
                   (list->vector
                    (map (lambda (n t)
                           (list (cons "name" (sym->json n))
                                 (cons "type" (type->json t))))
                         elt-name* type*))))]
      [(tenum ,src ,enum-name ,elt-name ,elt-name* ...)
       (list (cons "type-name" "Enum")
             (cons "name" (sym->json enum-name))
             (cons "elements"
                   (list->vector
                    (map sym->json (cons elt-name elt-name*)))))]
      [(talias ,src ,nominal? ,type-name ,type)
       (if nominal?
           (list (cons "type-name" "Alias")
                 (cons "name" (sym->json type-name))
                 (cons "type" (type->json type)))
           (type->json type))]
      [(tcontract ,src ,contract-name (,elt-name* ,pure-dcl* (,type** ...) ,type*) ...)
       (list (cons "type-name" "Contract")
             (cons "name" (sym->json contract-name))
             (cons "circuits"
                   (list->vector
                    (map (lambda (en pd ts t)
                           (list (cons "name" (sym->json en))
                                 (cons "pure" pd)
                                 (cons "argument-types"
                                       (list->vector (map type->json ts)))
                                 (cons "result-type" (type->json t))))
                         elt-name* pure-dcl* type** type*))))]
      [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
       (adt-type->json (clean-adt-name adt-name) adt-arg*)]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Type variant in runtime-ir emission: ~s"
         (unparse-Ltypescript type))]))

  ;; Render an ADT's type-arg list as the matching JSON, mirroring
  ;; save-contract-info-passes.ss::serialize-adt.
  (define (adt-type->json adt-name adt-arg*)
    (let ([head (cons "type-name" (sym->json adt-name))])
      (case adt-name
        [(Cell)
         (list head (cons "type" (adt-arg->json (car adt-arg*))))]
        [(Counter)
         (list head)]
        [(Map)
         (list head
               (cons "key" (adt-arg->json (car adt-arg*)))
               (cons "value" (adt-arg->json (cadr adt-arg*))))]
        [(Set List)
         (list head (cons "type" (adt-arg->json (car adt-arg*))))]
        [(MerkleTree HistoricMerkleTree)
         (list head
               (cons "depth" (adt-arg->json (car adt-arg*)))
               (cons "type" (adt-arg->json (cadr adt-arg*))))]
        [else
         (internal-errorf 'runtime-ir
           "unhandled ADT '~s' in runtime-ir emission" adt-name)])))

  (define (adt-arg->json arg)
    (nanopass-case (Ltypescript Public-Ledger-ADT-Arg) arg
      [,type (type->json type)]
      [,nat (number->json nat)]))

  ;; Same `storage` key shape as save-contract-info-passes.ss for
  ;; ledger-field-record JSON.
  (define (serialize-storage-adt adt-name adt-arg*)
    (let ([head (cons "storage" (sym->json (clean-adt-name adt-name)))])
      (case (clean-adt-name adt-name)
        [(Cell)
         (list head (cons "type" (adt-arg->json (car adt-arg*))))]
        [(Counter)
         (list head)]
        [(Map)
         (list head
               (cons "key" (adt-arg->json (car adt-arg*)))
               (cons "value" (adt-arg->json (cadr adt-arg*))))]
        [(Set List)
         (list head (cons "type" (adt-arg->json (car adt-arg*))))]
        [(MerkleTree HistoricMerkleTree)
         (list head
               (cons "depth" (adt-arg->json (car adt-arg*)))
               (cons "type" (adt-arg->json (cadr adt-arg*))))]
        [else
         (internal-errorf 'runtime-ir
           "unhandled storage-ADT '~s' in runtime-ir emission" adt-name)])))

  (define (unwrap-to-adt type)
    (nanopass-case (Ltypescript Type) type
      [(talias ,src ,nominal? ,type-name ,type)
       (unwrap-to-adt type)]
      [else type]))

  ;; ------------------------------------------------------------------
  ;; Body rendering — Statements, Expressions, ADT-Op invocations, vm-ops.
  ;;
  ;; Walks Ltypescript Statement and Expression nodes and renders each
  ;; as JSON.  Any unhandled node hard-errors (no silent partials).
  ;; ------------------------------------------------------------------

  ;; Render a vm-instruction (a `vminstr` record from `expand-vm-code`)
  ;; as one JSON object.  The instruction has an `op` symbol and a list
  ;; of (arg-name . VMop-or-list-of-VMop) pairs.
  ;; A vm-op argument value contains VMsuppress if the recipe's
  ;; substitution evaluated to one of the `(suppress-null ...)` /
  ;; `(suppress-zero ...)` sentinels.  The JS emitter drops the entire
  ;; instruction in that case (per `(guard ((suppressed-condition? c)
  ;; q*) ...)` in typescript-passes); the IR matches that behaviour.
  (define (value-has-suppress? v)
    (cond
      [(VMop? v)
       (VMop-case v
         [(VMsuppress) #t]
         [else #f])]
      [(list? v) (ormap value-has-suppress? v)]
      [else #f]))

  (define (vminstr-has-suppress? instr)
    (ormap (lambda (arg) (value-has-suppress? (cdr arg)))
           (vminstr-arg* instr)))

  (define (vminstr->json instr)
    (let ([op-name (vminstr-op instr)]
          [args (vminstr-arg* instr)])
      (cons (cons "op" op-name)
            (map (lambda (arg)
                   ;; expand-vm-code already returns string keys; just
                   ;; pass through.
                   (let ([k (car arg)])
                     (cons (if (symbol? k) (symbol->string k) k)
                           (vmop->json (cdr arg)))))
                 args))))

  (define (vminstrs->json-vector vminstr*)
    (list->vector
     (map vminstr->json
          (filter (lambda (i) (not (vminstr-has-suppress? i)))
                  vminstr*))))

  ;; Render a single VMop record (or a list of them, for path values)
  ;; as a JSON datum.  Keys mirror the VMop datatype constructors.
  (define (vmop->json v)
    (cond
      [(vmref-expr? v)
       (list (cons "vm" "ref")
             (cons "type" (type->json (vmref-expr-type v)))
             (cons "value" (vmref-expr-expr-json v)))]
      [(VMop? v) (vmop-record->json v)]
      [(list? v)
       (list->vector (map vmop->json v))]
      [(integer? v) (number->json v)]
      [(boolean? v) v]
      [(symbol? v) (symbol->string v)]
      [else
       (internal-errorf 'runtime-ir
         "unhandled vm-op argument value: ~s" v)]))

  (define (vmop-record->json v)
    (VMop-case v
      [(VMstack) "@stack"]
      [(VMvoid) (void)]
      [(VMsuppress)
       ;; The `suppress` sentinel is only legal as a top-level instruction
       ;; argument that the JS emitter omits.  At IR-emission time we
       ;; preserve it so consumers can apply the same omission rule.
       '(("vm" . "suppress"))]
      [(VM+ x y)
       (list (cons "vm" "add")
             (cons "left" (vmop->json x))
             (cons "right" (vmop->json y)))]
      [(VMalign value bytes)
       (list (cons "vm" "align")
             (cons "value" (number->json value))
             (cons "bytes" bytes))]
      [(VMaligned-concat x*)
       (list (cons "vm" "aligned-concat")
             (cons "values" (list->vector (map vmop->json x*))))]
      [(VMnull type)
       (list (cons "vm" "null")
             (cons "type" (type->json type)))]
      [(VMmax-sizeof type)
       (list (cons "vm" "max-sizeof")
             (cons "type" (type->json type)))]
      [(VMvalue->int x)
       (list (cons "vm" "value->int")
             (cons "value" (vmop->json x)))]
      [(VMcoin-commit coin recipient)
       (list (cons "vm" "coin-commit")
             (cons "coin" (vmop->json coin))
             (cons "recipient" (vmop->json recipient)))]
      [(VMleaf-hash x)
       (list (cons "vm" "leaf-hash")
             (cons "value" (vmop->json x)))]
      [(VMstate-value-null)
       '(("vm" . "state-value")
         ("kind" . "null"))]
      [(VMstate-value-cell val)
       (list (cons "vm" "state-value")
             (cons "kind" "cell")
             (cons "value" (vmop->json val)))]
      [(VMstate-value-ADT val type)
       (list (cons "vm" "state-value")
             (cons "kind" "adt")
             (cons "value" (vmop->json val))
             (cons "type" (type->json type)))]
      [(VMstate-value-map key* val*)
       (list (cons "vm" "state-value")
             (cons "kind" "map")
             (cons "entries"
                   (list->vector
                    (map (lambda (k v)
                           (list (cons "key" (vmop->json k))
                                 (cons "value" (vmop->json v))))
                         key* val*))))]
      [(VMstate-value-merkle-tree depth key* val*)
       (list (cons "vm" "state-value")
             (cons "kind" "merkle-tree")
             (cons "depth" (vmop->json depth))
             (cons "entries"
                   (list->vector
                    (map (lambda (k v)
                           (list (cons "key" (vmop->json k))
                                 (cons "value" (vmop->json v))))
                         key* val*))))]
      [(VMstate-value-array val*)
       (list (cons "vm" "state-value")
             (cons "kind" "array")
             (cons "values" (list->vector (map vmop->json val*))))]))

  ;; ------------------------------------------------------------------
  ;; Statement and Expression walkers.
  ;; ------------------------------------------------------------------

  ;; Render an Argument (used as a `local` binding name + type) as JSON.
  (define (local->json local)
    (nanopass-case (Ltypescript Argument) local
      [(,var-name ,type)
       (list (cons "name" (sym->json (id-sym var-name)))
             (cons "type" (type->json type)))]))

  ;; Render an Ltypescript Statement as JSON.
  (define (statement->json stmt)
    (nanopass-case (Ltypescript Statement) stmt
      [(seq ,src ,stmt* ... ,stmt)
       (list (cons "stmt" "seq")
             (cons "items"
                   (list->vector
                    (append (map statement->json stmt*)
                            (list (statement->json stmt))))))]
      [(if ,src ,expr0 ,stmt1)
       (list (cons "stmt" "if")
             (cons "cond" (expression->json expr0))
             (cons "then" (statement->json stmt1)))]
      [(if ,src ,expr0 ,stmt1 ,stmt2)
       (list (cons "stmt" "if")
             (cons "cond" (expression->json expr0))
             (cons "then" (statement->json stmt1))
             (cons "else" (statement->json stmt2)))]
      [(const ,src ,local ,expr)
       (list (cons "stmt" "const")
             (cons "binding" (local->json local))
             (cons "value" (expression->json expr)))]
      [(const ,src (,local* ...))
       (list (cons "stmt" "const-destructure")
             (cons "bindings"
                   (list->vector (map local->json local*))))]
      [(statement-expression ,expr)
       (list (cons "stmt" "expr")
             (cons "value" (expression->json expr)))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Statement variant: ~s"
         (unparse-Ltypescript stmt))]))

  ;; Render an Ltypescript Expression as JSON.
  (define (expression->json expr)
    (nanopass-case (Ltypescript Expression) expr
      [(quote ,src ,datum)
       (list (cons "expr" "literal")
             (cons "value" (datum->json datum)))]
      [(var-ref ,src ,var-name)
       (list (cons "expr" "var")
             (cons "name" (sym->json (id-sym var-name))))]
      [(default ,src ,type)
       (list (cons "expr" "default")
             (cons "type" (type->json type)))]
      [(if ,src ,expr0 ,expr1 ,expr2)
       (list (cons "expr" "if")
             (cons "cond" (expression->json expr0))
             (cons "then" (expression->json expr1))
             (cons "else" (expression->json expr2)))]
      [(elt-ref ,src ,expr ,elt-name ,nat)
       (list (cons "expr" "elt-ref")
             (cons "value" (expression->json expr))
             (cons "field" (sym->json elt-name))
             (cons "index" (number->json nat)))]
      [(enum-ref ,src ,type ,elt-name)
       (list (cons "expr" "enum-ref")
             (cons "type" (type->json type))
             (cons "variant" (sym->json elt-name)))]
      [(tuple ,src ,tuple-arg* ...)
       (list (cons "expr" "tuple")
             (cons "items"
                   (list->vector (map tuple-arg->json tuple-arg*))))]
      [(vector ,src ,tuple-arg* ...)
       (list (cons "expr" "vector")
             (cons "items"
                   (list->vector (map tuple-arg->json tuple-arg*))))]
      [(tuple-ref ,src ,expr ,kindex)
       (list (cons "expr" "tuple-ref")
             (cons "value" (expression->json expr))
             (cons "index" kindex))]
      [(tuple-slice ,src ,type ,expr ,kindex ,len)
       (list (cons "expr" "tuple-slice")
             (cons "value" (expression->json expr))
             (cons "start" kindex)
             (cons "length" len)
             (cons "result-type" (type->json type)))]
      [(vector-ref ,src ,type ,expr ,index)
       (list (cons "expr" "vector-ref")
             (cons "value" (expression->json expr))
             (cons "index" (expression->json index))
             (cons "result-type" (type->json type)))]
      [(vector-slice ,src ,type ,expr ,index ,len)
       (list (cons "expr" "vector-slice")
             (cons "value" (expression->json expr))
             (cons "start" (expression->json index))
             (cons "length" len)
             (cons "result-type" (type->json type)))]
      [(bytes-ref ,src ,type ,expr ,index)
       (list (cons "expr" "bytes-ref")
             (cons "value" (expression->json expr))
             (cons "index" (expression->json index))
             (cons "result-type" (type->json type)))]
      [(bytes-slice ,src ,type ,expr ,index ,len)
       (list (cons "expr" "bytes-slice")
             (cons "value" (expression->json expr))
             (cons "start" (expression->json index))
             (cons "length" len)
             (cons "result-type" (type->json type)))]
      [(+ ,src ,mbits ,expr1 ,expr2)
       (binop->json "+" mbits expr1 expr2)]
      [(- ,src ,mbits ,expr1 ,expr2)
       (binop->json "-" mbits expr1 expr2)]
      [(* ,src ,mbits ,expr1 ,expr2)
       (binop->json "*" mbits expr1 expr2)]
      [(< ,src ,bits ,expr1 ,expr2)
       (binop->json "<" bits expr1 expr2)]
      [(<= ,src ,bits ,expr1 ,expr2)
       (binop->json "<=" bits expr1 expr2)]
      [(> ,src ,bits ,expr1 ,expr2)
       (binop->json ">" bits expr1 expr2)]
      [(>= ,src ,bits ,expr1 ,expr2)
       (binop->json ">=" bits expr1 expr2)]
      [(== ,src ,type ,expr1 ,expr2)
       (list (cons "expr" "eq")
             (cons "type" (type->json type))
             (cons "left" (expression->json expr1))
             (cons "right" (expression->json expr2)))]
      [(!= ,src ,type ,expr1 ,expr2)
       (list (cons "expr" "neq")
             (cons "type" (type->json type))
             (cons "left" (expression->json expr1))
             (cons "right" (expression->json expr2)))]
      [(and ,src ,expr1 ,expr2)
       (list (cons "expr" "and")
             (cons "left" (expression->json expr1))
             (cons "right" (expression->json expr2)))]
      [(or ,src ,expr1 ,expr2)
       (list (cons "expr" "or")
             (cons "left" (expression->json expr1))
             (cons "right" (expression->json expr2)))]
      [(not ,src ,expr)
       (list (cons "expr" "not")
             (cons "value" (expression->json expr)))]
      [(= ,src ,var-name ,expr)
       (list (cons "expr" "assign")
             (cons "name" (sym->json (id-sym var-name)))
             (cons "value" (expression->json expr)))]
      [(call ,src ,function-name ,expr* ...)
       (list (cons "expr" "call")
             (cons "function" (sym->json (id-sym function-name)))
             (cons "arguments"
                   (list->vector (map expression->json expr*))))]
      [(new ,src ,type ,expr* ...)
       (list (cons "expr" "new")
             (cons "type" (type->json type))
             (cons "arguments"
                   (list->vector (map expression->json expr*))))]
      [(seq ,src ,expr* ... ,expr)
       (list (cons "expr" "seq")
             (cons "items"
                   (list->vector
                    (append (map expression->json expr*)
                            (list (expression->json expr))))))]
      [(field->bytes ,src ,len ,expr)
       (list (cons "expr" "field->bytes")
             (cons "length" len)
             (cons "value" (expression->json expr)))]
      [(cast-from-bytes ,src ,type ,len ,expr)
       (list (cons "expr" "cast-from-bytes")
             (cons "to" (type->json type))
             (cons "length" len)
             (cons "value" (expression->json expr)))]
      [(vector->bytes ,src ,len ,expr)
       (list (cons "expr" "vector->bytes")
             (cons "length" len)
             (cons "value" (expression->json expr)))]
      [(bytes->vector ,src ,len ,expr)
       (list (cons "expr" "bytes->vector")
             (cons "length" len)
             (cons "value" (expression->json expr)))]
      [(cast-from-enum ,src ,type ,type^ ,expr)
       (list (cons "expr" "cast-from-enum")
             (cons "from" (type->json type^))
             (cons "to" (type->json type))
             (cons "value" (expression->json expr)))]
      [(cast-to-enum ,src ,type ,type^ ,expr)
       (list (cons "expr" "cast-to-enum")
             (cons "from" (type->json type^))
             (cons "to" (type->json type))
             (cons "value" (expression->json expr)))]
      [(safe-cast ,src ,type ,type^ ,expr)
       (list (cons "expr" "safe-cast")
             (cons "to" (type->json type))
             (cons "from" (type->json type^))
             (cons "value" (expression->json expr)))]
      [(downcast-unsigned ,src ,nat? ,nat ,expr)
       (list (cons "expr" "downcast-unsigned")
             (cons "from-bits" (if nat? (number->json nat?) (void)))
             (cons "to-bits" (number->json nat))
             (cons "value" (expression->json expr)))]
      [(assert ,src ,expr ,mesg)
       (list (cons "expr" "assert")
             (cons "cond" (expression->json expr))
             (cons "message" mesg))]
      [(map ,src ,len ,fun ,map-arg ,map-arg* ...)
       (list (cons "expr" "map")
             (cons "length" len)
             (cons "function" (function->json fun))
             (cons "arguments"
                   (list->vector
                    (map map-arg->json (cons map-arg map-arg*)))))]
      [(fold ,src ,len ,fun (,expr0 ,type0) ,map-arg ,map-arg* ...)
       (list (cons "expr" "fold")
             (cons "length" len)
             (cons "function" (function->json fun))
             (cons "initial"
                   (list (cons "value" (expression->json expr0))
                         (cons "type" (type->json type0))))
             (cons "arguments"
                   (list->vector
                    (map map-arg->json (cons map-arg map-arg*)))))]
      [(public-ledger ,src ,ledger-field-name ,sugar (,path-elt* ...) ,src^ ,adt-op ,expr* ...)
       (adt-op-invocation->json ledger-field-name path-elt* adt-op expr*)]
      [(contract-call ,src ,elt-name (,expr ,type) ,expr* ...)
       (list (cons "expr" "contract-call")
             (cons "circuit" (sym->json elt-name))
             (cons "address" (expression->json expr))
             (cons "address-type" (type->json type))
             (cons "arguments"
                   (list->vector (map expression->json expr*))))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Expression variant: ~s"
         (unparse-Ltypescript expr))]))

  (define (binop->json op-str bits expr1 expr2)
    (list (cons "expr" "binop")
          (cons "op" op-str)
          (cons "bits" (if bits (number->json bits) (void)))
          (cons "left" (expression->json expr1))
          (cons "right" (expression->json expr2))))

  ;; Render a Tuple-Argument (used inside tuple/vector/bytes constructions).
  (define (tuple-arg->json arg)
    (nanopass-case (Ltypescript Tuple-Argument) arg
      [(single ,src ,expr)
       (list (cons "kind" "single")
             (cons "value" (expression->json expr)))]
      [(spread ,src ,nat ,expr)
       (list (cons "kind" "spread")
             (cons "length" (number->json nat))
             (cons "value" (expression->json expr)))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Tuple-Argument variant: ~s"
         (unparse-Ltypescript arg))]))

  ;; Render a Function (used inside map/fold).
  (define (function->json fun)
    (nanopass-case (Ltypescript Function) fun
      [(fref ,src ,function-name)
       (list (cons "kind" "fref")
             (cons "name" (sym->json (id-sym function-name))))]
      [(circuit ,src (,arg* ...) ,type ,stmt)
       (list (cons "kind" "lambda")
             (cons "arguments"
                   (list->vector
                    (map (lambda (a)
                           (nanopass-case (Ltypescript Argument) a
                             [(,var-name ,type)
                              (list (cons "name" (sym->json (id-sym var-name)))
                                    (cons "type" (type->json type)))]))
                         arg*)))
             (cons "result-type" (type->json type))
             (cons "body" (statement->json stmt)))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Function variant: ~s"
         (unparse-Ltypescript fun))]))

  ;; Render a Map-Argument (used inside map/fold).
  (define (map-arg->json marg)
    (nanopass-case (Ltypescript Map-Argument) marg
      [(,expr ,type ,type^)
       (list (cons "value" (expression->json expr))
             (cons "type" (type->json type))
             (cons "cast-to" (type->json type^)))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Map-Argument variant: ~s"
         (unparse-Ltypescript marg))]))

  ;; Render a Path-Element (used inside ADT-Op path*).
  (define (path-elt->json path-elt)
    (nanopass-case (Ltypescript Path-Element) path-elt
      [,path-index
       (list (cons "kind" "literal")
             (cons "index" path-index))]
      [(,src ,type ,expr)
       (list (cons "kind" "expr")
             (cons "type" (type->json type))
             (cons "value" (expression->json expr)))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled Path-Element variant: ~s"
         (unparse-Ltypescript path-elt))]))

  ;; Render a literal datum (the `,datum` of `(quote ,datum)`).
  (define (datum->json d)
    (cond
      [(boolean? d) d]
      [(integer? d) (number->json d)]
      [(bytevector? d)
       (let ([n (bytevector-length d)])
         (let loop ([i 0] [chars '()])
           (if (= i n)
               (list->string (reverse chars))
               (let* ([b (bytevector-u8-ref d i)]
                      [hi (quotient b 16)]
                      [lo (remainder b 16)])
                 (loop (+ i 1)
                       (cons* (hex-digit lo) (hex-digit hi) chars))))))]
      [else
       (internal-errorf 'runtime-ir
         "unhandled literal datum: ~s" d)]))

  (define (hex-digit n)
    (if (< n 10)
        (integer->char (+ (char->integer #\0) n))
        (integer->char (+ (char->integer #\a) (- n 10)))))

  ;; Render an ADT-Op invocation.  The IR carries the symbolic name +
  ;; the pre-expanded VM op sequence.
  (define (adt-op-invocation->json ledger-field-name path-elt* adt-op expr*)
    (nanopass-case (Ltypescript ADT-Op) adt-op
      [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
       (let* ([op-class-sym (cond
                              [(symbol? op-class) op-class]
                              [(pair? op-class) (car op-class)]
                              [else op-class])]
              [vminstr*
                (expand-vm-code
                  #f
                  (map (lambda (path-elt)
                         (nanopass-case (Ltypescript Path-Element) path-elt
                           [,path-index (VMalign path-index 1)]
                           [(,src ,type ,expr)
                            ;; Runtime-computed path elements carry
                            ;; their type + IR expression so consumers
                            ;; can evaluate the expression to recover
                            ;; the path value.
                            (make-vmref-expr type (expression->json expr))]))
                       path-elt*)
                  #f
                  (append (map cons adt-formal* adt-arg*)
                          (map (lambda (vn t e)
                                 ;; Bind each call-site argument to a
                                 ;; vmref-expr carrying the IR
                                 ;; expression.  The vm-op's argument
                                 ;; slots will then carry the actual
                                 ;; expression IR rather than a
                                 ;; placeholder.
                                 (cons (id-sym vn)
                                       (make-vmref-expr t (expression->json e))))
                               var-name* type* expr*))
                  (vm-code-code vm-code))])
         (list (cons "expr" "adt-op")
               (cons "adt" (sym->json (clean-adt-name adt-name)))
               (cons "operation" (sym->json ledger-op))
               (cons "op-class" (sym->json op-class-sym))
               (cons "field"
                     (if ledger-field-name
                         (sym->json (id-sym ledger-field-name))
                         (void)))
               (cons "field-path"
                     (list->vector (map path-elt->json path-elt*)))
               (cons "arguments"
                     (list->vector (map expression->json expr*)))
               (cons "result-type" (type->json type))
               (cons "vm-ops"
                     (vminstrs->json-vector vminstr*))))]))

  ;; ------------------------------------------------------------------
  ;; Top-level pass.
  ;; ------------------------------------------------------------------

  (define-pass print-runtime-ir : Ltypescript (ir proof-circuit-name*) -> Ltypescript ()
    (definitions
      ;; Render argument list of a circuit/witness/native — same shape as
      ;; save-contract-info-passes.ss::Argument.
      (define (Argument arg)
        (nanopass-case (Ltypescript Argument) arg
          [(,var-name ,type)
           (list (cons "name" (sym->json (id-sym var-name)))
                 (cons "type" (type->json type)))]))

      ;; Walk the public-ledger-array tree and flatten to bindings.
      (define (flatten-pl-array pl-array)
        (nanopass-case (Ltypescript Public-Ledger-Array) pl-array
          [(public-ledger-array ,pl-array-elt* ...)
           (apply append (map flatten-pl-array-elt pl-array-elt*))]))
      (define (flatten-pl-array-elt elt)
        (nanopass-case (Ltypescript Public-Ledger-Array-Element) elt
          [,pl-array (flatten-pl-array pl-array)]
          [,public-binding (list public-binding)]))

      ;; Build the descriptor table from the program's tdescs node.
      ;; The JS backend names descriptors `_descriptor_N` where N is
      ;; the positional index in the (descriptor-id* type*) list.  We
      ;; key the IR's descriptor table by N (as a string) for direct
      ;; correspondence with the JS naming.
      (define (descriptors->json tdescs)
        (nanopass-case (Ltypescript Type-Descriptors) tdescs
          [(type-descriptors ,descriptor-table (,descriptor-id* ,type*) ...)
           (let loop ([ids descriptor-id*] [types type*] [idx 0] [acc '()])
             (cond
               [(null? ids) (reverse acc)]
               [else
                (loop (cdr ids) (cdr types) (+ idx 1)
                      (cons (cons (number->string idx)
                                  (type->json (car types)))
                            acc))]))]))

      ;; Build the JSON-renderable body for one circuit definition.
      ;; If the circuit is exported with one or more external names,
      ;; emits one record per external name.  Otherwise emits a single
      ;; record under the internal name (helper / non-exported circuits
      ;; need to be available to consumers because exported circuits
      ;; transitively call them — e.g. `mintShieldedToken` is a stdlib
      ;; helper imported by user contracts).
      (define (Circuit-Body cdefn export-alist proof-circuit-name*)
        (nanopass-case (Ltypescript Circuit-Definition) cdefn
          [(circuit ,src ,function-name (,arg* ...) ,type ,stmt)
           (let ([sym (id-sym function-name)])
             (let ([external-names
                    (fold-right
                      (lambda (a names)
                        (if (eq? (cdr a) function-name)
                            (cons (symbol->string (car a)) names)
                            names))
                      '() export-alist)])
               (let ([names (if (null? external-names)
                                (list (symbol->string sym))
                                external-names)])
                 (map (lambda (n)
                        (list
                          (cons "name" n)
                          (cons "internal-name" (sym->json sym))
                          (cons "exported" (id-exported? function-name))
                          (cons "pure" (id-pure? function-name))
                          (cons "proof" (and (memq sym proof-circuit-name*) #t))
                          (cons "arguments"
                                (list->vector (map Argument arg*)))
                          (cons "result-type" (type->json type))
                          (cons "body" (statement->json stmt))))
                      names))))]))

      ;; Render a witness declaration.
      (define (Witness wdecl)
        (nanopass-case (Ltypescript Program-Element) wdecl
          [(witness ,src ,function-name (,arg* ...) ,type)
           (list (list (cons "name" (sym->json (id-sym function-name)))
                       (cons "arguments"
                             (list->vector (map Argument arg*)))
                       (cons "result-type" (type->json type))))]
          [else '()]))

      ;; Render a native declaration.
      (define (Native ndecl)
        (nanopass-case (Ltypescript Program-Element) ndecl
          [(native ,src ,function-name ,native-entry (,arg* ...) ,type)
           (list (list (cons "name" (sym->json (id-sym function-name)))
                       (cons "host-symbol"
                             (sym->json (native-entry-function native-entry)))
                       (cons "class"
                             (sym->json (native-entry-class native-entry)))
                       (cons "arguments"
                             (list->vector (map Argument arg*)))
                       (cons "result-type" (type->json type))))]
          [else '()]))

      ;; Kernel declarations are compactc-internal bindings between
      ;; user code and the magic Kernel ADT.  The IR consumer doesn't
      ;; need them as a separate section: kernel calls render as
      ;; ADT-Op invocations with `adt: "Kernel"` inside circuit bodies,
      ;; and the canonical kernel-function catalog is fixed by the
      ;; runtime-version field (consumers carry the catalog matching
      ;; their runtime version).
      (define (Kernel kdecl) '())

      (define (kernel-adt? adt-name)
        (eq? (clean-adt-name adt-name) 'Kernel))

      ;; Render a ledger-field declaration's metadata, mirroring
      ;; save-contract-info-passes.ss::LedgerField.  Skips bindings
      ;; whose ADT is `Kernel` — that's the kernel-effects array, an
      ;; internal slot at index 0 of the public ledger that consumers
      ;; should not see as a user-visible ledger field.  Kernel
      ;; operations are still represented in the IR via ADT-Op
      ;; invocations on `adt: "Kernel"` inside circuit bodies.
      (define (LedgerField pelt)
        (nanopass-case (Ltypescript Program-Element) pelt
          [(public-ledger-declaration ,pl-array ,lconstructor)
           (let ([bindings (flatten-pl-array pl-array)])
             (fold-right
              (lambda (pb acc)
                (nanopass-case (Ltypescript Public-Ledger-Binding) pb
                  [(,src ,ledger-field-name (,path-index* ...) ,type)
                   (let ([name (sym->json (id-sym ledger-field-name))]
                         [index (if (and (pair? path-index*)
                                         (null? (cdr path-index*)))
                                    (car path-index*)
                                    (list->vector path-index*))]
                         [exported (id-exported? ledger-field-name)]
                         [unwrapped (unwrap-to-adt type)])
                     (nanopass-case (Ltypescript Type) unwrapped
                       [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
                        (if (kernel-adt? adt-name)
                            acc
                            (cons
                             (cons*
                              (cons "name" name)
                              (cons "index" index)
                              (cons "exported" exported)
                              (serialize-storage-adt adt-name adt-arg*))
                             acc))]
                       [else
                        (internal-errorf 'runtime-ir
                          "unhandled non-ADT ledger field type at ~s" name)]))]))
              '() bindings))]
          [else '()]))

      ;; Build the constructor body section.
      (define (Ledger-Constructor lconstructor)
        (nanopass-case (Ltypescript Ledger-Constructor) lconstructor
          [(constructor ,src (,arg* ...) ,stmt)
           (list (cons "arguments" (list->vector (map Argument arg*)))
                 (cons "body" (statement->json stmt)))]))

      ;; Build the initial-state skeleton.  Walks pl-array recursively:
      ;; each pl-array becomes a state-value array; each public-binding
      ;; becomes a Null leaf.
      (define (build-init-skeleton pl-array)
        (nanopass-case (Ltypescript Public-Ledger-Array) pl-array
          [(public-ledger-array ,pl-array-elt* ...)
           (list (cons "kind" "array")
                 (cons "items"
                       (list->vector
                        (map build-init-skeleton-elt pl-array-elt*))))]))
      (define (build-init-skeleton-elt elt)
        (nanopass-case (Ltypescript Public-Ledger-Array-Element) elt
          [,pl-array (build-init-skeleton pl-array)]
          [,public-binding '(("kind" . "null"))]))

      ;; Find an ADT's `resetToDefault` op record by name.  Used to
      ;; expand the init VM ops for each ledger field.
      (define (find-adt-op-by-name name adt-op*)
        (let loop ([rest adt-op*])
          (cond
            [(null? rest) #f]
            [else
             (let ([op (car rest)])
               (nanopass-case (Ltypescript ADT-Op) op
                 [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
                  (if (eq? ledger-op name)
                      op
                      (loop (cdr rest)))]))])))

      ;; Build the init VM ops for one public-binding by expanding its
      ;; ADT's `resetToDefault` recipe.  The path is the binding's
      ;; path-index list (each path-index becomes a VMalign 1-byte value).
      (define (build-init-ops-for-binding pb)
        (nanopass-case (Ltypescript Public-Ledger-Binding) pb
          [(,src ,ledger-field-name (,path-index* ...) ,type)
           (let ([unwrapped (unwrap-to-adt type)])
             (nanopass-case (Ltypescript Type) unwrapped
               [(tadt ,src ,adt-name ([,adt-formal* ,adt-arg*] ...) ,vm-expr (,adt-op* ...) (,adt-rt-op* ...))
                ;; Skip Kernel — it's not a user field.
                (cond
                  [(kernel-adt? adt-name) '()]
                  [else
                   (let ([reset-op (find-adt-op-by-name 'resetToDefault adt-op*)])
                     (cond
                       [(not reset-op) '()]
                       [else
                        (nanopass-case (Ltypescript ADT-Op) reset-op
                          [(,ledger-op ,op-class (,adt-name (,adt-formal* ,adt-arg*) ...) ((,var-name* ,type*) ...) ,type ,vm-code)
                           (let* ([op-class-sym (cond
                                                  [(symbol? op-class) op-class]
                                                  [(pair? op-class) (car op-class)]
                                                  [else op-class])]
                                  [vminstr*
                                    (expand-vm-code
                                     #f
                                     (map (lambda (pi) (VMalign pi 1)) path-index*)
                                     #f
                                     (map cons adt-formal* adt-arg*)
                                     (vm-code-code vm-code))])
                             (list
                              (list
                               (cons "expr" "adt-op")
                               (cons "adt" (sym->json (clean-adt-name adt-name)))
                               (cons "operation" (sym->json ledger-op))
                               (cons "op-class" (sym->json op-class-sym))
                               (cons "field" (sym->json (id-sym ledger-field-name)))
                               (cons "field-path"
                                     (list->vector
                                      (map (lambda (pi)
                                             (list (cons "kind" "literal")
                                                   (cons "index" pi)))
                                           path-index*)))
                               (cons "arguments" (vector))
                               (cons "result-type" (type->json type))
                               (cons "vm-ops"
                                     (vminstrs->json-vector vminstr*)))))])]))])]
               [else '()]))]))

      ;; Walk the entire pl-array tree and concatenate init ops.
      (define (build-init-ops pl-array)
        (nanopass-case (Ltypescript Public-Ledger-Array) pl-array
          [(public-ledger-array ,pl-array-elt* ...)
           (apply append
             (map (lambda (elt)
                    (nanopass-case (Ltypescript Public-Ledger-Array-Element) elt
                      [,pl-array (build-init-ops pl-array)]
                      [,public-binding (build-init-ops-for-binding public-binding)]))
                  pl-array-elt*))])))

    (Program : Program (ir) -> Program ()
      [(program ,src ((,export-name* ,name*) ...) ,tdescs ,pelt* ...)
       (let ([op (get-target-port 'runtime-ir.json)])
         (let ([export-alist (map cons export-name* name*)])
           (print-json op
             (list
               (cons "schema-version" schema-version)
               (cons "compiler-version" compiler-version-string)
               (cons "language-version" language-version-string)
               (cons "runtime-version" runtime-version-string)
               ;; Metadata sections (mirror contract-info.json so consumers
               ;; need only this file).
               (cons "ledger"
                     (list->vector (fold-right
                                     (lambda (p acc) (append (LedgerField p) acc))
                                     '() pelt*)))
               (cons "witnesses"
                     (list->vector (fold-right
                                     (lambda (p acc) (append (Witness p) acc))
                                     '() pelt*)))
               (cons "natives"
                     (list->vector (fold-right
                                     (lambda (p acc) (append (Native p) acc))
                                     '() pelt*)))
               (cons "kernels"
                     (list->vector (fold-right
                                     (lambda (p acc) (append (Kernel p) acc))
                                     '() pelt*)))
               (cons "circuits"
                     (list->vector
                       (fold-right
                         (lambda (p acc)
                           (nanopass-case (Ltypescript Program-Element) p
                             [(circuit ,src ,function-name (,arg* ...) ,type ,stmt)
                              (append (Circuit-Body p export-alist proof-circuit-name*) acc)]
                             [else acc]))
                         '() pelt*)))
               ;; Type descriptor table.
               (cons "descriptors" (descriptors->json tdescs))
               ;; Constructor body — combines the auto-generated
               ;; initialization (skeleton state-value tree, init vm-ops
               ;; from each ledger field's resetToDefault recipe,
               ;; setOperation registrations for provable circuits) with
               ;; the user-written `constructor() {...}` stmt body.
               (cons "constructor"
                     (let loop ([rem pelt*])
                       (cond
                         [(null? rem)
                          (list (cons "arguments" (vector))
                                (cons "initial-state"
                                      '(("kind" . "array") ("items" . #())))
                                (cons "init-ops" (vector))
                                (cons "register-operations"
                                      (list->vector
                                       (map symbol->string proof-circuit-name*)))
                                (cons "body" (list (cons "stmt" "noop"))))]
                         [else
                          (let ([p (car rem)])
                            (nanopass-case (Ltypescript Program-Element) p
                              [(public-ledger-declaration ,pl-array ,lconstructor)
                               (let ([base (Ledger-Constructor lconstructor)])
                                 (append
                                  (list (car base))   ; arguments
                                  (list (cons "initial-state"
                                              (build-init-skeleton pl-array)))
                                  (list (cons "init-ops"
                                              (list->vector (build-init-ops pl-array))))
                                  (list (cons "register-operations"
                                              (list->vector
                                               (map symbol->string proof-circuit-name*))))
                                  (cdr base)))]   ; body
                              [else (loop (cdr rem))]))])))
               ;; External-contract declarations.  Currently empty —
               ;; the cross-contract surface in Ltypescript needs the
               ;; ECDecl shape walked once we have a fixture exercising
               ;; it.  Listed for forward-compat.
               (cons "external-contracts" (vector))
               ;; Pure-circuit bodies, mirrored from circuit-bodies but
               ;; selecting only the pure ones.  Currently overlaps with
               ;; `circuits` (the proof flag distinguishes them).
               (cons "pure-circuits" (vector))))))
         ir]))

  (define-passes runtime-ir-passes
    (print-runtime-ir Ltypescript)))
