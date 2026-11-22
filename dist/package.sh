#!/bin/sh
# dist/package.sh — builds a release package of Nihil for one platform:
#
#   dist/package.sh linux-x86_64 OUTDIR NIHILC1
#   dist/package.sh macos-arm64  OUTDIR NIHILC1_NATIVE RT_O
#
# writes OUTDIR/nihil-PLATFORM.tar.gz (the name stays the same in every release, so
# releases/latest/download/nihil-PLATFORM.tar.gz is always the newest) and its .sha256.
# Inside: nihil-VERSION/{bin/nihil, libexec/nihil/…, VERSION, LICENSE, README.md, CHANGELOG.md}.
set -eu
cd "$(dirname "$0")/.."
[ $# -ge 3 ] || { echo "usage: dist/package.sh linux-x86_64|macos-arm64 OUTDIR COMPILER [RT_O]" >&2; exit 2; }
platform=$1
outdir=$2
version=$(cat VERSION)
mkdir -p "$outdir"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root=$stage/nihil-$version
mkdir -p "$root/bin" "$root/libexec/nihil"
cp dist/nihil "$root/bin/nihil"
chmod 755 "$root/bin/nihil"
cp VERSION LICENSE README.md CHANGELOG.md "$root/"
case $platform in
    linux-x86_64)
        cp "$3" "$root/libexec/nihil/nihilc1"
        chmod 755 "$root/libexec/nihil/nihilc1"
        ;;
    macos-arm64)
        [ $# -ge 4 ] || { echo "macos-arm64 needs NIHILC1_NATIVE and RT_O" >&2; exit 2; }
        cp "$3" "$root/libexec/nihil/nihilc1-native"
        chmod 755 "$root/libexec/nihil/nihilc1-native"
        cp "$4" "$root/libexec/nihil/rt.o"
        cp macos/translate.py "$root/libexec/nihil/translate.py"
        ;;
    *)
        echo "unknown platform: $platform" >&2
        exit 2
        ;;
esac
tarball=$outdir/nihil-$platform.tar.gz
tar -czf "$tarball" -C "$stage" "nihil-$version"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$outdir" && sha256sum "nihil-$platform.tar.gz" > "nihil-$platform.tar.gz.sha256")
else
    (cd "$outdir" && shasum -a 256 "nihil-$platform.tar.gz" > "nihil-$platform.tar.gz.sha256")
fi
echo "$tarball"
