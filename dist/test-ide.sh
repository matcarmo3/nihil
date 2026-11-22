#!/bin/sh
# dist/test-ide.sh NIHIL — starts `nihil ide` of an installed Nihil on port 8799 with a temporary
# workspace, then, through its API, lists the workspace, runs examples/learn/04_methods.nihil and
# checks what it printed. The release workflow runs it on every platform.
set -eu
nihil=$1
ws=$(mktemp -d)
url=http://127.0.0.1:8799
NIHIL_WORKSPACE=$ws NIHIL_IDE_PORT=8799 "$nihil" ide --no-window > "$ws.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; pkill -f "$ws" 2>/dev/null || true; rm -rf "$ws" "$ws.log"' EXIT
i=0
until curl -fs -o /dev/null "$url/"; do
    i=$((i + 1))
    [ $i -lt 50 ] || { cat "$ws.log"; echo "the IDE did not start" >&2; exit 1; }
    sleep 0.2
done
token=$(curl -fs "$url/" | grep -o -E '[0-9a-f]{64}' | head -1)
curl -fs -H "x-nihil-token: $token" "$url/api/projects" | grep -q '"Nihil (workspace)"'
run=$(curl -fs -H "x-nihil-token: $token" -H 'content-type: application/json' \
    -d "{\"project\": \"$ws\", \"path\": \"examples/learn/04_methods.nihil\"}" "$url/api/run")
echo "$run" | grep -q '"ok": true' || { echo "run: $run" >&2; exit 1; }
id=$(echo "$run" | sed -n 's/.*"run": \([0-9]*\).*/\1/p')
i=0
while :; do
    out=$(curl -fs -H "x-nihil-token: $token" "$url/api/output?id=$id")
    case $out in *'"code": 0'*) break ;; esac
    i=$((i + 1))
    [ $i -lt 50 ] || { echo "output: $out" >&2; exit 1; }
    sleep 0.2
done
echo "$out" | grep -q '144 6765' || { echo "output: $out" >&2; exit 1; }
echo "the IDE works: it compiled and ran examples/learn/04_methods.nihil"
