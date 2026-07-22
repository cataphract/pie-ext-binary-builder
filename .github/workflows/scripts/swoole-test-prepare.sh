#!/bin/sh

set -eu

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"

# shellcheck source=.github/workflows/scripts/docker-workspace.sh
. "$GITHUB_WORKSPACE/.github/workflows/scripts/docker-workspace.sh"

docker run --rm \
    -v "$DOCKER_WORKSPACE/ext/tests/include/lib:/app" \
    -w /app \
    composer:2 \
    install --no-interaction --no-progress --prefer-dist --ignore-platform-reqs
