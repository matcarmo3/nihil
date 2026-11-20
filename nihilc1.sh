#!/usr/bin/env bash
# nihilc1.sh — the stage 1 compiler (written in Nihil) with the same command line
# as nihilc:  nihilc1.sh input.nihil [output]
#
# nihilc1 reads the program path from stdin, reads the files itself (including
# those included with @), writes the executable to stdout and errors to
# stderr. This script saves the output and makes it executable.
#   NIHILC1=path   chooses another stage 1 binary (e.g. build/nihilc2)
#   NIHIL_O0=1     no optimizations (the same bytes as stage 0)
set -u
dir=$(cd "$(dirname "$0")" && pwd)
bin=${NIHILC1:-$dir/build/nihilc1}
[ $# -ge 1 ] || { echo "nihilc: usage: nihilc <input.nihil> [output]" >&2; exit 1; }
src=$1
out=${2:-a.out}
[ -f "$src" ] && [ -r "$src" ] || { echo "nihilc: could not open $src" >&2; exit 1; }
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT
option=""; [ "${NIHIL_O0:-0}" = 1 ] && option="-O0 "
printf '%s%s\n' "$option" "$src" | "$bin" > "$tmp" || exit 1
if cat "$tmp" 2>/dev/null > "$out" && chmod 755 "$out" 2>/dev/null; then
    exit 0
fi
echo "nihilc: could not create $out" >&2
exit 1
