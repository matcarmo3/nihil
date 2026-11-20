#!/usr/bin/env bash
# Compiles every valid program in tests/ with nihilc (stage 0) and with nihilc1
# (stage 1, without optimizations: NIHIL_O0=1) and requires byte-for-byte
# identical executables.
set -u
cd "$(dirname "$0")/.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ok=0; failed=0
for src in tests/*.nihil; do
  base=$(basename "${src%.nihil}")
  ./build/nihilc "$src" "$TMP/a" 2>/dev/null || continue
  if ! NIHIL_O0=1 ./nihilc1.sh "$src" "$TMP/b" 2>"$TMP/err"; then
    failed=$((failed + 1)); echo "FAILED  $base: nihilc1 did not compile it: $(head -c 300 "$TMP/err")"; continue
  fi
  if cmp -s "$TMP/a" "$TMP/b"; then ok=$((ok + 1))
  else failed=$((failed + 1)); echo "FAILED  $base: different bytes ($(cmp "$TMP/a" "$TMP/b" | head -1))"; fi
done
echo "$ok identical, $failed different"
[ "$failed" -eq 0 ]
