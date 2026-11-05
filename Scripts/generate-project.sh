#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
# Git clones embed their exact revision; source archives have no Git metadata.
if [ -z "${GIT_COMMIT_SHA:-}" ]; then
    if [ "$(git rev-parse --show-toplevel 2>/dev/null || true)" = "$(pwd -P)" ]; then
        GIT_COMMIT_SHA=$(git rev-parse --short=12 HEAD)
    else
        GIT_COMMIT_SHA=source-archive
    fi
fi
export GIT_COMMIT_SHA
exec xcodegen generate
