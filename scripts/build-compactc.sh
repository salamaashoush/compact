#!/usr/bin/env bash
#
# Build compactc + format-compact + fixup-compact from source without nix.
#
# Mirrors what the `compactc` derivation in flake.nix does at the
# scheme / Chez level — useful when developing the patched fork on a
# host that doesn't have nix installed (the IOG-flake build is the
# only documented path otherwise).
#
# Dependencies:
#   - chezscheme (`scheme` or `chez` on PATH)
#   - nanopass-framework-scheme @ f3100cedaf9ed7fb89647a770d855997b32cf17e
#   - rough-draft @ 6a5e64aa325d2fd7ab1e161cfcb45ba2f9a057de
#
# The script auto-clones the two scheme deps under `obj/deps/` if they
# aren't already there. Pin commits match `_sources/generated.nix`.
#
# Output: obj/compactc, obj/format-compact, obj/fixup-compact.
# These are Chez-script-binary form (chez --program); they need the
# zkir / zkir-v3 binaries on PATH at runtime to actually compile a
# .compact file (zkir is shelled out for the proof-key step). Use
# /home/sashoush/.compact/versions/<latest>/<triple>/{zkir,zkir-v3}
# from the upstream installer for those.

set -euo pipefail

cd "$(dirname "$0")/.."

NANOPASS_REV=f3100cedaf9ed7fb89647a770d855997b32cf17e
ROUGH_DRAFT_REV=6a5e64aa325d2fd7ab1e161cfcb45ba2f9a057de

if command -v scheme &>/dev/null; then
  SCHEME=scheme
elif command -v chez &>/dev/null; then
  SCHEME=chez
else
  echo "error: neither 'scheme' nor 'chez' on PATH; install Chez Scheme first" >&2
  exit 1
fi

mkdir -p obj/deps
if [ ! -d obj/deps/nanopass ]; then
  git clone --quiet https://github.com/nanopass/nanopass-framework-scheme.git obj/deps/nanopass
  ( cd obj/deps/nanopass && git checkout --quiet "$NANOPASS_REV" )
fi
if [ ! -d obj/deps/rough-draft ]; then
  git clone --quiet https://github.com/akeep/rough-draft.git obj/deps/rough-draft
  ( cd obj/deps/rough-draft && git checkout --quiet "$ROUGH_DRAFT_REV" )
fi

mkdir -p obj/compiler

scheme_path="$(command -v "$SCHEME")"
sed -e "s;/usr/bin/env .*;${scheme_path} --program;" compiler/compactc.ss > obj/compiler/compactc.ss
sed -e "s;/usr/bin/env .*;${scheme_path} --program;" compiler/format-compact.ss > obj/compiler/format-compact.ss
sed -e "s;/usr/bin/env .*;${scheme_path} --program;" compiler/fixup-compact.ss > obj/compiler/fixup-compact.ss

export CHEZSCHEMELIBDIRS="compiler::obj/compiler:third_party/compiler::obj/third_party/compiler:obj/deps/nanopass::obj/nanopass:obj/deps/rough-draft/src::obj/rough-draft:srcMaps::obj/srcMaps::obj/compiler"

"$SCHEME" -q << 'END'
(reset-handler abort)
(optimize-level 2)
(compile-imported-libraries #t)
(generate-wpo-files #t)
(generate-inspector-information #f)
(compile-profile #f)
(compile-program "obj/compiler/compactc.ss" "obj/compiler/compactc.so")
(compile-program "obj/compiler/format-compact.ss" "obj/compiler/format-compact.so")
(compile-program "obj/compiler/fixup-compact.ss" "obj/compiler/fixup-compact.so")
(compile-whole-program "obj/compiler/compactc.wpo" "obj/compactc")
(compile-whole-program "obj/compiler/format-compact.wpo" "obj/format-compact")
(compile-whole-program "obj/compiler/fixup-compact.wpo" "obj/fixup-compact")
END

chmod +x obj/compactc obj/format-compact obj/fixup-compact
echo "built: obj/{compactc,format-compact,fixup-compact}"
