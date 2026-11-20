#!/usr/bin/env bash
# Test suite (SPEC §13).
#   tests/NAME.nihil          compiled, run and compared with:
#     NAME.out              expected stdout       (default: empty)
#     NAME.code             expected exit code    (default: 0)
#     NAME.stderr           expected stderr       (optional; not checked without the file)
#     NAME.in               program stdin         (default: empty)
#   tests/errors/NAME.nihil   compilation must FAIL;
#     NAME.err              text expected in the compiler's stderr
#   DIRS="tests tests/stage1" also runs the stage-1-only tests (M7+)
#   NIHILC=path chooses the compiler (default: build/nihilc)
set -u
cd "$(dirname "$0")/.."
NIHILC=${NIHILC:-./build/nihilc}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ok=0; failed=0
pass() { ok=$((ok + 1)); }
fail() { failed=$((failed + 1)); echo "FAILED  $1: $2"; }

run_dir() {
  local dir=$1 src name base bin
  for src in "$dir"/*.nihil; do
    [ -e "$src" ] || continue
    name=${src%.nihil}; base=${name#tests/}; bin="$TMP/$(basename "$name")"
    if ! "$NIHILC" "$src" "$bin" 2>"$TMP/err"; then fail "$base" "compilation: $(cat "$TMP/err")"; continue; fi
    warnings=$(readelf -h -l "$bin" 2>&1 >/dev/null)
    if [ -n "$warnings" ]; then fail "$base" "readelf: $warnings"; continue; fi
    perm=$(stat -c %a "$bin")
    if [ "$perm" != 755 ]; then fail "$base" "permission $perm, expected 755"; continue; fi
    input=/dev/null; [ -f "$name.in" ] && input="$name.in"
    "$bin" >"$TMP/out" 2>"$TMP/stderr" <"$input"; code=$?
    exp_code=0; [ -f "$name.code" ] && exp_code=$(cat "$name.code")
    : >"$TMP/exp"; [ -f "$name.out" ] && cp "$name.out" "$TMP/exp"
    if [ "$code" != "$exp_code" ]; then fail "$base" "exit code $code, expected $exp_code $(cat "$TMP/stderr")"; continue; fi
    if ! cmp -s "$TMP/out" "$TMP/exp"; then fail "$base" "different output (expected / got):"; diff "$TMP/exp" "$TMP/out" | head -20; continue; fi
    if [ -f "$name.stderr" ] && ! cmp -s "$TMP/stderr" "$name.stderr"; then fail "$base" "different stderr (expected / got):"; diff "$name.stderr" "$TMP/stderr" | head -20; continue; fi
    pass
  done

  for src in "$dir"/errors/*.nihil; do
    [ -e "$src" ] || continue
    name=${src%.nihil}; base=${name#tests/}
    if "$NIHILC" "$src" "$TMP/x" 2>"$TMP/err"; then fail "$base" "should fail, but compiled"; continue; fi
    if [ -f "$name.err" ] && ! grep -qF -- "$(cat "$name.err")" "$TMP/err"; then fail "$base" "message: $(cat "$TMP/err")"; continue; fi
    pass
  done
}

for d in ${DIRS:-tests}; do run_dir "$d"; done

# --- command line ---
if "$NIHILC" 2>"$TMP/err"; then fail cli/no-arguments "should fail"
elif grep -q "usage:" "$TMP/err"; then pass; else fail cli/no-arguments "no usage message"; fi

if "$NIHILC" tests/does-not-exist.nihil "$TMP/x" 2>"$TMP/err"; then fail cli/missing-input "should fail"
elif grep -q "does-not-exist.nihil" "$TMP/err"; then pass; else fail cli/missing-input "path missing from the message: $(cat "$TMP/err")"; fi

if "$NIHILC" tests/empty.nihil "$TMP/no-dir/x" 2>"$TMP/err"; then fail cli/bad-output "should fail"
elif grep -q "no-dir/x" "$TMP/err"; then pass; else fail cli/bad-output "message: $(cat "$TMP/err")"; fi

# output overwriting an existing file without execute permission
printf 'junk' >"$TMP/old"; chmod 600 "$TMP/old"
if "$NIHILC" tests/empty.nihil "$TMP/old" && [ "$(stat -c %a "$TMP/old")" = 755 ] && "$TMP/old"; then pass
else fail cli/overwrite "did not become an executable with mode 755"; fi

# default output a.out
( cd "$TMP" && "$OLDPWD/$NIHILC" "$OLDPWD/tests/empty.nihil" && ./a.out ) && pass || fail cli/a.out "a.out not created or does not run"

echo "$ok passed, $failed failed"
[ "$failed" -eq 0 ]
