#!/bin/sh
set -eu

plist="${1:?usage: verify-build-metadata.sh /path/to/Cast.app/Info.plist}"
expected="$(git -C "$(dirname "$0")/.." rev-parse --short=12 HEAD)"
actual="$(/usr/libexec/PlistBuddy -c 'Print :CastGitSHA' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"

case "$build" in ''|*[!0-9]*) echo "invalid build number: $build" >&2; exit 1;; esac
[ "$build" -gt 0 ] || { echo "build number must be positive" >&2; exit 1; }
[ "$actual" = "$expected" ] || { echo "expected SHA $expected, got $actual" >&2; exit 1; }
echo "build=$build sha=$actual"
