#!/usr/bin/env bash
# Builds git refs for compare.py, each in its own worktree, and collects each
# one's binaries and runtime in OUT_DIR/<label>/{bin,runtime}.
#
# Usage: build_variants.sh OUT_DIR label=ref [label=ref ...]
# Example:
#   git fetch origin master rewatch-ocaml-port rewatch-ocaml-in-process
#   build_variants.sh ~/rescript-variants master=origin/master \
#     port=origin/rewatch-ocaml-port in-process=origin/rewatch-ocaml-in-process
#
# A worktree is kept in OUT_DIR/src-<label> and reused, so a later run only
# rebuilds what changed. Needs the usual build setup (opam switch, yarn).
set -euo pipefail

if [ $# -lt 2 ]; then
  sed -n '2,13p' "$0"
  exit 2
fi

repo=$(cd "$(dirname "$0")/../../.." && pwd)
mkdir -p "$1"
out=$(cd "$1" && pwd)
shift

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-x64 ;;
  Linux-aarch64 | Linux-arm64) platform=linux-arm64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  *) echo "unsupported platform $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

for spec in "$@"; do
  label=${spec%%=*}
  ref=${spec#*=}
  source="$out/src-$label"
  echo "== $label ($ref)"
  if [ -d "$source" ]; then
    git -C "$source" checkout --quiet --detach "$ref"
  else
    git -C "$repo" worktree add --quiet --detach "$source" "$ref"
  fi
  git -C "$source" log -1 --format='   %h %s'
  # The runtime and Belt are rebuilt from scratch: an interrupted earlier run
  # may have left damaged artifacts behind.
  (cd "$source" && make && make clean-lib && make lib) > "$out/build-$label.log" 2>&1 || {
    echo "build failed, see $out/build-$label.log" >&2
    exit 1
  }
  rm -rf "${out:?}/$label"
  mkdir -p "$out/$label/runtime"
  cp -R "$source/packages/@rescript/$platform/bin" "$out/$label/bin"
  # Only what the compiler reads: the runtime's node_modules links back into
  # the repository.
  cp -R "$source/packages/@rescript/runtime/lib" \
    "$source/packages/@rescript/runtime/package.json" \
    "$source/packages/@rescript/runtime/rescript.json" "$out/$label/runtime/"
  git -C "$source" rev-parse HEAD > "$out/$label/commit"
  echo "   -> $out/$label"
done
