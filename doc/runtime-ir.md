# Runtime IR (`compiler/runtime-ir.json`)

> Status: **draft**. This document specifies a complete, language-agnostic JSON
> serialization of the post-analysis Compact IR (`Ltypescript`), suitable for any runtime —
> Rust, Python, Go, Java, etc. — to consume in lieu of the JS output produced by the
> existing TypeScript backend. The IR covers everything `typescript-passes.ss` consumes
> from `Ltypescript`: every Statement, Expression, Type, ADT-Op, vm-op, off-chain helper,
> and Pelt kind. There is no construct deferred to a future schema version — the emitter
> hard-errors on any analyzed-IR node it cannot serialize.

## Goals

1. **Language-agnostic.** Any runtime that can read JSON and execute the Midnight VM op set
   should be able to deploy and call any contract using only this file plus the
   contract's `zkir/`, `keys/`, and `contract-info.json`.
2. **Faithful.** Anything `typescript-passes.ss` emits that affects runtime behavior has
   an IR equivalent. JS-specific niceties (typeError messages, source-map markers, VS
   Code line metadata) are JS-only and stay out.
3. **Closed taxonomy.** Every IR node kind is enumerated below. The emitter pass hard-errors
   on any analyzed-IR construct it doesn't yet serialize — never silently emits a partial.
4. **Versioned.** The top-level `schema-version` field starts at `1`. Additive changes
   (new node kinds, new fields) are minor; breaking changes bump the major.

## File location

Emitted next to `contract-info.json`:

```
<target-directory>/
├── compiler/
│   ├── contract-info.json     # existing
│   └── runtime-ir.json        # new
├── contract/
│   ├── index.js               # existing TS backend output
│   ├── index.d.ts
│   └── index.js.map
├── zkir/
└── keys/
```

`runtime-ir.json` is **additive** — `contract-info.json` is unchanged.

## Top-level shape

```jsonc
{
  "schema-version": 1,

  // Versioning matches contract-info.json:
  "compiler-version":  "0.30.0",
  "language-version":  "0.22.0",
  "runtime-version":   "0.15.0",
  "ledger-version":    "...",        // not in contract-info.json today; useful here

  // Same metadata as contract-info.json (intentional duplication so consumers
  // need only one file). Identical shape — `tools/diff-ir.ts` validates this.
  "ledger":     [...],
  "witnesses":  [...],
  "circuits":   [...],
  "contracts":  [...],

  // NEW: type descriptor table — every type used at any runtime boundary
  // (circuit args, witness results, kernel-call args, ledger-field cells).
  // Keyed by integer id (matches `_descriptor_N` in the JS output).
  "descriptors": { "0": {...}, "1": {...}, ... },

  // NEW: constructor body.
  "constructor": { "arguments": [...], "body": <statement> },

  // NEW: per-circuit body. One entry per exported provable circuit.
  "circuit-bodies": [
    { "name": "...", "arguments": [...], "result-type": ..., "body": <statement> }
  ],

  // NEW: pure circuits (no proof, host-side helper functions).
  "pure-circuits": [
    { "name": "...", "arguments": [...], "result-type": ..., "body": <statement> }
  ]
}
```

## Type descriptors

Every type used at a runtime boundary gets an entry in the descriptor table. Descriptors
are referenced by id everywhere a type appears. This eliminates duplication and matches the
`_descriptor_N` numbering in the JS backend.

```jsonc
{
  "0": { "kind": "uint",    "maxval": "18446744073709551615", "alignment-bytes": 8 },
  "1": { "kind": "uint",    "maxval": "65535",                "alignment-bytes": 2 },
  "2": { "kind": "boolean" },
  "3": { "kind": "bytes",   "length": 32 },
  "4": { "kind": "field"  },
  "5": { "kind": "vector",  "length": 4, "element": "3" },
  "6": { "kind": "tuple",   "elements": ["0", "3"] },
  "7": { "kind": "struct",  "name": "Either", "fields": [
                              {"name": "is_left", "descriptor": "2"},
                              {"name": "left",    "descriptor": "3"},
                              {"name": "right",   "descriptor": "3"}] },
  "8": { "kind": "enum",    "name": "State", "variants": ["UNSET", "SET"] },
  "9": { "kind": "alias",   "name": "ContractAddress", "of": "3" },
  "10":{ "kind": "opaque",  "ts-type": "..."  /* present only for FFI types */ }
}
```

Big integers use string encoding (`"18446744073709551615"`) because standard JSON `number`
caps at 2^53; this matches `contract-info.json`'s `maxval` convention.

## Ledger fields and witnesses (preserved from `contract-info.json`)

```jsonc
"ledger": [
  { "name": "round",       "index": 0, "exported": true,  "storage": "Counter" },
  { "name": "owners",      "index": 1, "exported": false, "storage": "Map",
    "key": {"type-name": "Bytes", "length": 32},
    "value": {"type-name": "Uint", "maxval": "..."} }
],
"witnesses": [
  { "name": "localCount", "arguments": [], "result-type": {...} }
]
```

## Circuit metadata (preserved from `contract-info.json`)

```jsonc
"circuits": [
  {
    "name": "incrementBy", "pure": false, "proof": true,
    "arguments": [{"name": "amount", "type": {...}}],
    "result-type": {...}
  }
]
```

The `body` for each circuit lives in `circuit-bodies`, not here, so consumers can ignore
bodies if they only need metadata (matches the `contract-info.json` use case).

## Statement IR

Recursive. Every Compact statement maps to exactly one `stmt` kind.

```jsonc
// Sequence — execute statements in order.
{ "stmt": "seq",   "items": [<stmt>, ...] }

// Constant binding — bind `name` to the value of `value` for the rest of the enclosing seq.
{ "stmt": "const", "name": "observed_0", "value": <expr> }

// Destructuring binding — same as `const` but for tuple/struct returns.
{ "stmt": "const-destructure", "names": ["a", "b"], "value": <expr> }

// Conditional. Else is optional.
{ "stmt": "if",    "cond": <expr>, "then": <stmt>, "else": <stmt> | null }

// Expression-as-statement (for side effects: ledger queries, witness calls, kernel calls).
{ "stmt": "expr",  "value": <expr> }

// Assertion. Halts the circuit on false.
{ "stmt": "assert", "cond": <expr>, "message": "..." }

// Assignment. Only legal for `let` locals; ledger writes go through ADT-Op invocations.
{ "stmt": "assign", "name": "x", "value": <expr> }

// Return value of the enclosing circuit/function.
{ "stmt": "return", "value": <expr> }
```

## Expression IR

```jsonc
// Local variable reference.
{ "expr": "var",  "name": "observed_0" }

// Circuit/function argument reference.
{ "expr": "arg",  "name": "amount" }

// Typed literal. `value` is a JSON-safe representation of the literal: string for big ints
// and bytes (hex), number for small ints, bool for bool, null for void.
{ "expr": "literal", "descriptor": "0", "value": "42" }

// Tuple / struct / vector construction.
{ "expr": "tuple",  "items": [<expr>, ...] }
{ "expr": "struct", "name": "Either",
  "fields": {"is_left": <expr>, "left": <expr>, "right": <expr>} }
{ "expr": "vector", "items": [<expr>, ...] }

// Element/field access.
{ "expr": "elt-ref",   "value": <expr>, "field": "left" }
{ "expr": "tuple-ref", "value": <expr>, "index": 0 }
{ "expr": "vector-ref","value": <expr>, "index": <expr> }
{ "expr": "bytes-ref", "value": <expr>, "index": <expr> }

// Slicing.
{ "expr": "vector-slice", "value": <expr>, "start": <expr>, "length": <int> }
{ "expr": "tuple-slice",  "value": <expr>, "start": <int>,  "length": <int> }

// Boolean / arithmetic.
{ "expr": "not", "value": <expr> }
{ "expr": "and", "left": <expr>, "right": <expr> }
{ "expr": "or",  "left": <expr>, "right": <expr> }
{ "expr": "eq",  "left": <expr>, "right": <expr> }
{ "expr": "neq", "left": <expr>, "right": <expr> }
{ "expr": "binop", "op": "+|-|*|<|<=|>|>=", "bits": <int> | null, "left": <expr>, "right": <expr> }
// `if` as expression (yields a value); statement-form `if` lives under "stmt": "if".
{ "expr": "if", "cond": <expr>, "then": <expr>, "else": <expr> }

// Type cast.
{ "expr": "cast", "from": "<descriptor>", "to": "<descriptor>", "value": <expr> }
{ "expr": "safe-cast",          "to": "<descriptor>", "value": <expr>, "max-attempts": 10 }
{ "expr": "downcast-unsigned",  "from-bits": <int> | null, "to-bits": <int>, "value": <expr> }

// Bytes/vector/field interconversion.
{ "expr": "bytes->vector", "length": <int>, "value": <expr> }
{ "expr": "vector->bytes", "length": <int>, "value": <expr> }
{ "expr": "bytes->field",  "length": <int>, "value": <expr> }
{ "expr": "field->bytes",  "length": <int>, "value": <expr> }
{ "expr": "cast-from-bytes", "to": "<descriptor>", "length": <int>, "value": <expr> }

// Enum coercion.
{ "expr": "enum-ref", "enum": "State", "variant": "SET" }
{ "expr": "cast-to-enum",   "to": "State",   "value": <expr> }
{ "expr": "cast-from-enum", "from": "State", "value": <expr> }

// Default-value-of-type. Expands at compile time to the type's zero/empty form.
{ "expr": "default", "descriptor": "<id>" }

// Function/native call.
{ "expr": "call", "function": "persistentHash", "arguments": [<expr>, ...] }

// Sequenced expression — evaluates the items in order, returns the last.
{ "expr": "seq", "items": [<expr>, ...] }

// Inline let-binding (separate from `const` statement; an Ltypescript inheritance from
// earlier languages, surviving when the post-disclosure pass leaves a let inside an
// expression position).
{ "expr": "let", "bindings": [{"name": "x", "value": <expr>}, ...], "body": <expr> }

// Spread inside a tuple/vector construction.
{ "expr": "spread", "value": <expr> }

// Cross-contract circuit invocation.
{ "expr": "contract-call",
  "contract": "OtherRegistry", "circuit": "lookup",
  "address":  <expr>, "arguments": [<expr>, ...], "result-descriptor": "<id>" }

// Witness invocation. Returns (next-private-state, witness-result).
// The IR is explicit: caller is responsible for threading next-private-state.
{ "expr": "witness-call",
  "witness": "localCount",
  "arguments": [<expr>, ...],
  "result-descriptor": "0",
  "private-transcript-output-descriptor": "0" }

// ADT-Op invocation — the only way circuits read or write ledger state OR invoke
// kernel operations. `adt` is "Kernel" for kernel calls, otherwise the ADT name
// of a ledger field. `field-path` is empty for kernel calls; for ledger ops it is
// the path from the public ledger root to the operated-on field. `arguments` are
// the user-level arguments to the operation. The IR also embeds the pre-expanded
// `vm-ops` for consumers that don't carry a kernel/ADT catalog.
{ "expr": "adt-op",
  "adt": "Counter" | "Map" | "Kernel" | ...,
  "operation": "increment" | "lookup" | "claimZswapCoinReceive" | ...,
  "op-class": "read" | "update" | "write" | "remove",
  "field-path": [<path-elt>, ...],
  "arguments":  [<expr>, ...],
  "result-descriptor": "0" | null,
  "vm-ops": [<vm-op>, ...] }

// Off-chain crypto helpers (host-side, not VM ops). Appear inside `vm-ops` arrays
// when an op has `value` derived from one of the rt-* helpers, but also as
// standalone expressions when a circuit body computes a value off-chain to feed
// into a subsequent op.
{ "expr": "off-chain", "helper": "coin-commit" | "leaf-hash" | "aligned-concat" |
                                  "null" | "max-sizeof" | "value->int",
                       "arguments": [<expr>, ...] }
```

## VM op IR

The `vm-ops` array inside each `adt-op` expression contains the pre-expanded sequence of
on-chain VM operations (the `expand-vm-code` output). Every op is one of these:

```jsonc
{ "op": "noop"  }
{ "op": "pop"   }
{ "op": "dup",     "n": <int> }
{ "op": "swap",    "n": <int> }
{ "op": "push",    "storage": <bool>, "value": <state-value> }
{ "op": "idx",     "cached": <bool>, "push-path": <bool>, "path": [<path-elt>, ...] }
{ "op": "ins",     "cached": <bool>, "n": <int> }
{ "op": "rem",     "cached": <bool> }
{ "op": "addi",    "immediate": <expr> }   // expr resolves to an integer at runtime
{ "op": "subi",    "immediate": <expr> }
{ "op": "lt"    }
{ "op": "eq"    }
{ "op": "neg"   }
{ "op": "size"  }
{ "op": "member"}
{ "op": "concat",  "cached": <bool>, "n": <int> }
{ "op": "popeq",   "cached": <bool>, "result-descriptor": "<descriptor>" }
{ "op": "ckpt"  }
{ "op": "new",     "value": <state-value> }
{ "op": "branch",  "...": "..." }   // populated as new ops are discovered in midnight-ledger.ss
```

`<path-elt>` is one of:

```jsonc
{ "path": "literal", "descriptor": "<id>", "value": "..." }   // align(value, bytes) literal
{ "path": "stack" }                                           // top-of-stack reference
{ "path": "expr",    "descriptor": "<id>", "value": <expr> }  // computed-at-runtime
```

`<state-value>` (used by `push.value` and `new.value`):

```jsonc
{ "kind": "null" }
{ "kind": "cell",        "descriptor": "<id>", "value": "..." }
{ "kind": "cell-expr",   "descriptor": "<id>", "value": <expr> }   // runtime-computed
{ "kind": "array",       "items": [<state-value>, ...] }
{ "kind": "map",         "entries": [{"key": <state-value>, "value": <state-value>}, ...] }
{ "kind": "merkle-tree", "depth": <int>, "entries": [...] }
```

## Op-class semantics

Mirrors `midnight-ledger.ss`:

- `read` — pure ledger-state extraction. No state change. Always ends with `popeq`.
- `update` — modifies an existing field's contents.
- `write` — overwrites a field with a new value.
- `remove` — deletes from a collection (or resets to default).

`op-class` lets consumers distinguish read-only vs state-mutating calls without scanning the
op list. Kernel calls all use `update` (they record claims into the kernel-effects array).

## Worked example: registry contract

For `crates/test-fixtures/contracts/registry/registry.compact` (single circuit
`incrementBy(amount: Uint<16>): Uint<64>` reading a `localCount(): Uint<64>` witness and
incrementing the on-chain `round: Counter`):

```jsonc
{
  "schema-version": 1,
  "compiler-version": "0.30.0",
  "language-version": "0.22.0",
  "runtime-version":  "0.15.0",

  "ledger":    [{"name": "round", "index": 0, "exported": true, "storage": "Counter"}],
  "witnesses": [{"name": "localCount", "arguments": [],
                 "result-type": {"type-name": "Uint", "maxval": "18446744073709551615"}}],
  "circuits":  [{"name": "incrementBy", "pure": false, "proof": true,
                 "arguments": [{"name": "amount", "type": {"type-name": "Uint", "maxval": "65535"}}],
                 "result-type": {"type-name": "Uint", "maxval": "18446744073709551615"}}],
  "contracts": [],

  "descriptors": {
    "0": {"kind": "uint", "maxval": "18446744073709551615", "alignment-bytes": 8},
    "1": {"kind": "uint", "maxval": "65535",                "alignment-bytes": 2},
    "7": {"kind": "uint", "maxval": "255",                  "alignment-bytes": 1}
  },

  "constructor": {
    "arguments": [],
    "body": {
      "stmt": "expr",
      "value": {
        "expr": "adt-op",
        "adt": "_PublicLedger",   // synthetic ADT for top-level state init
        "operation": "init",
        "op-class": "write",
        "field-path": [],
        "arguments": [],
        "result-descriptor": null,
        "vm-ops": [
          {"op": "push", "storage": false, "value": {"kind": "cell", "descriptor": "7", "value": "0"}},
          {"op": "push", "storage": true,  "value": {"kind": "cell", "descriptor": "0", "value": "0"}},
          {"op": "ins",  "cached": false, "n": 1}
        ]
      }
    }
  },

  "circuit-bodies": [{
    "name": "incrementBy",
    "arguments": [{"name": "amount", "descriptor": "1"}],
    "result-descriptor": "0",
    "input-descriptors":  ["1"],
    "output-descriptor":  "0",
    "body": {
      "stmt": "seq",
      "items": [
        { "stmt": "const", "name": "observed_0",
          "value": { "expr": "witness-call",
                     "witness": "localCount",
                     "arguments": [],
                     "result-descriptor": "0",
                     "private-transcript-output-descriptor": "0" }},
        { "stmt": "expr",
          "value": { "expr": "adt-op",
                     "adt": "Counter",
                     "operation": "increment",
                     "op-class": "update",
                     "field-path": [{"path": "literal", "descriptor": "7", "value": "0"}],
                     "arguments": [{"expr": "arg", "name": "amount"}],
                     "result-descriptor": null,
                     "vm-ops": [
                       {"op": "idx", "cached": false, "push-path": true,
                        "path": [{"path": "literal", "descriptor": "7", "value": "0"}]},
                       {"op": "addi", "immediate": {"expr": "off-chain", "helper": "value->int",
                                                    "arguments": [{"expr": "arg", "name": "amount"}]}},
                       {"op": "ins", "cached": true, "n": 1}
                     ]}},
        { "stmt": "return", "value": { "expr": "var", "name": "observed_0" } }
      ]
    }
  }],

  "pure-circuits": []
}
```

Note how `(addi [immediate (rt-value->int amount)])` from `midnight-ledger.ss::Counter::increment`
becomes `{"op": "addi", "immediate": {"expr": "off-chain", "helper": "value->int", ...}}` —
the recipe's symbolic `(rt-value->int amount)` is preserved structurally in the IR, so a
Rust runtime can evaluate `amount` from the call args and feed the integer to its `Op::Addi`.

## What's intentionally not in IR

JS-specific concerns that don't affect runtime behavior:

- **Source maps** (`.js.map`) — debug info, not runtime.
- **Friendly type-error messages** (`__compactRuntime.typeError(...)`) — JS host concern;
  Rust runtimes generate their own type errors from descriptors.
- **VS Code metadata** — IDE concern, not runtime.
- **Runtime-version preamble** (`__compactRuntime.checkRuntimeVersion(...)`) — replaced by
  the IR's `runtime-version` field.
- **Pure-circuit JS bodies that are entirely `js-only` ledger ops** (e.g., `Set::iter`) — these
  are JS host helpers; non-JS runtimes implement equivalents natively. The IR still lists
  the function in `pure-circuits` with `body: {"stmt": "host-only"}` so consumers know it
  exists.

## Cross-contract calls

The `tcontract` type (declared in `Lsrc` and surviving through `Ltypescript`) and
`contract-call` expression let one contract invoke another. The IR represents this with:

```jsonc
// Top-level: external contracts referenced by this contract.
"external-contracts": [
  {
    "name": "OtherRegistry",
    "circuits": [
      { "name": "lookup", "pure": true,
        "argument-types": [{"type-name": "Bytes", "length": 32}],
        "result-type":   {"type-name": "Bytes", "length": 32} }
    ]
  }
]

// Inside any expression position:
{ "expr": "contract-call",
  "contract": "OtherRegistry",
  "circuit":  "lookup",
  "address":  <expr>,        // tcontract value carrying the deploy address
  "arguments": [<expr>, ...],
  "result-descriptor": "<id>" }
```

Cross-contract circuits do not have `body` IR — they're declared as an interface only. The
calling runtime resolves the address at deploy time (compactc embeds it via
`contractReferenceLocations`) and dispatches to the deployed contract's own `circuit-bodies`.

## Native declarations

`(native function-name native-entry args type)` IR — built-in functions implemented by the
runtime host (e.g. `persistentHash`):

```jsonc
"natives": [
  { "name": "persistentHash",
    "host-symbol": "persistentHash",
    "arguments": [{"name": "data", "descriptor": "<id>"}],
    "result-descriptor": "<id>",
    "disclosure-classes": ["disclose-input"] }
]
```

Inside expressions, native calls render as `{"expr": "call", "function": "persistentHash", ...}`
just like any other compile-time `call` (which is the form they take in `Ltypescript` after
`Lnodca` lowers to `(call src function-name expr* ...)`).

## Validation

Every IR change is validated against the four moonproof fixtures
(`crates/test-fixtures/contracts/{counter,registry,mint,vault}/`). The validation harness:

1. Compiles each fixture with the patched compactc — must succeed and emit `runtime-ir.json`.
2. Diffs `runtime-ir.json` against a checked-in expected file (golden test).
3. Loads the IR into a Rust interpreter and executes a deploy-then-call against an
   in-memory ledger; asserts equality with the hand-written `ContractExecutable`'s output
   from moonproof.

The third gate is the strongest: it proves the IR carries enough information to recover
exact Midnight-VM behavior without the JS runtime.

## Forward-compatibility policy

- New top-level fields (additive): no schema-version bump.
- New node kinds in `Statement` / `Expression` / vm-op taxonomy: no bump if existing nodes
  unchanged.
- Renamed or removed fields, semantics changes to existing nodes: major bump.
- Consumers MUST reject `schema-version` they don't recognize.
