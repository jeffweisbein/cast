#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
# Git clones embed their exact revision; source archives have no Git metadata.
if [ -z "${GIT_COMMIT_SHA:-}" ]; then
    GIT_COMMIT_SHA=$(git rev-parse --short=12 HEAD 2>/dev/null || printf '%s' source-archive)
fi
export GIT_COMMIT_SHA
exec xcodegen generate
