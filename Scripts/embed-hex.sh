#!/bin/sh
# Run after building and BEFORE signing Cast. Preserve the upstream helper signature.
# Usage: Scripts/embed-hex.sh /path/to/Cast.app /path/to/Hex.app
set -eu
cast_app="$1"
hex_app="$2"
test -f "$cast_app/Contents/Info.plist"
test -x "$hex_app/Contents/MacOS/hex"
/usr/bin/codesign --verify --deep --strict "$hex_app"
/usr/bin/codesign --verify -R '=anchor apple generic and identifier "anomaly.hex" and certificate leaf[subject.OU] = "5NZ4Q7NXJ4"' "$hex_app"
mkdir -p "$cast_app/Contents/Resources/Helpers"
/usr/bin/ditto "$hex_app" "$cast_app/Contents/Resources/Helpers/Hex.app"
/usr/bin/codesign --verify --deep --strict "$cast_app/Contents/Resources/Helpers/Hex.app"
