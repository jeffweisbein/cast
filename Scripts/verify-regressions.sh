#!/bin/sh
# Focused, offline checks. Not a substitute for native builds or device acceptance.
set -eu
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s Tests -p 'test_*.py' -v
python3 Tests/desktop_bridge_test.py -v
