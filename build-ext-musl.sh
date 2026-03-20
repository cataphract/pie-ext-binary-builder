#!/usr/bin/env bash

set -euo pipefail

IMAGE="ghcr.io/cataphract/php-minimal:8.4-release"
REPO="Imagick/imagick"
REF="4.8.1"
PACKAGES=""
CONFIGURE=""
PRE_SCRIPT=""
OPEN_SHELL=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --image)      IMAGE="$2";      shift 2 ;;
        --repo)       REPO="$2";       shift 2 ;;
        --ref)        REF="$2";        shift 2 ;;
        --packages)   PACKAGES="$2";   shift 2 ;;
        --configure)  CONFIGURE="$2";  shift 2 ;;
        --pre-script) PRE_SCRIPT="$2"; shift 2 ;;
        --shell)      OPEN_SHELL=1;    shift   ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

EXT_DIR="$(pwd)/ext"

if [[ ! -d "$EXT_DIR/.git" ]]; then
    echo "==> Cloning https://github.com/${REPO} @ ${REF} into ./ext"
    git clone --depth 1 --branch "$REF" "https://github.com/${REPO}.git" "$EXT_DIR"
else
    echo "==> ./ext already exists, skipping clone"
fi

APK_PART=""
if [[ -n "$PACKAGES" ]]; then
    APK_PART="apk add --no-cache ${PACKAGES} && "
fi

PRE_SCRIPT_PART=""
if [[ -n "$PRE_SCRIPT" ]]; then
    PRE_SCRIPT_PART="sh /workspace/${PRE_SCRIPT} && "
fi

BUILD_CMD="${APK_PART}${PRE_SCRIPT_PART}phpize && ./configure ${CONFIGURE} && make -j\$(nproc)"

echo "==> Building inside ${IMAGE}"
docker run --rm \
    -it \
    -v "$(pwd):/workspace" \
    -w /workspace/ext \
    "$IMAGE" \
    sh -c "$BUILD_CMD"

echo "==> Build complete. .so files:"
find "$EXT_DIR/modules" -name '*.so'

if [[ $OPEN_SHELL -eq 1 ]]; then
    echo "==> Opening shell inside container for analysis"
    docker run --rm -it \
        -v "$(pwd):/workspace" \
        -w /workspace/ext \
        "$IMAGE" \
        sh -c "${APK_PART}sh"
fi
