#!/bin/sh

set -eu

inside_container() {
    test_libc=${TEST_LIBC:?TEST_LIBC must be set}
    if [ -n "${TEST_PACKAGES:-}" ]; then
        case "$test_libc" in
            musl)
                # Package names come from a trusted workflow matrix.
                # shellcheck disable=SC2086
                apk add --no-cache $TEST_PACKAGES
                ;;
            glibc)
                apt-get update -q
                # Package names come from a trusted workflow matrix.
                # shellcheck disable=SC2086
                apt-get install -y -q $TEST_PACKAGES
                ;;
            *)
                echo "Unsupported test libc: $test_libc" >&2
                exit 2
                ;;
        esac
    fi

    if [ -n "${TEST_PRE_COMMAND:-}" ]; then
        sh -c "$TEST_PRE_COMMAND"
    fi

    if [ -n "${TEST_RUNTIME_SETUP_SCRIPT:-}" ]; then
        sh "/workspace/$TEST_RUNTIME_SETUP_SCRIPT"
    fi

    if [ -n "${TEST_INIT_SCRIPT:-}" ]; then
        php "/workspace/$TEST_INIT_SCRIPT"
    fi

    set --
    if [ "${TEST_EXTENSION_MODE:-argument}" = "argument" ]; then
        set -- "$@" -n
        if [ -n "${TEST_EXTRA_EXTENSION:-}" ]; then
            set -- "$@" -d "extension=/workspace/ext/$TEST_EXTRA_EXTENSION"
        fi
        if [ "${TEST_ZEND_EXTENSION:-}" = "true" ]; then
            extension_directive=zend_extension
        else
            extension_directive=extension
        fi
        set -- "$@" -d "$extension_directive=/workspace/ext/modules/$TEST_EXTENSION_NAME.so"
    fi

    if [ -n "${TEST_PHP_ARGS:-}" ]; then
        # Test-runner PHP arguments come from a trusted workflow matrix.
        # shellcheck disable=SC2086
        set -- "$@" $TEST_PHP_ARGS
    fi
    set -- "$@" --show-diff -q
    if [ -n "${TEST_ARGS:-}" ]; then
        # Test arguments come from a trusted workflow matrix.
        # shellcheck disable=SC2086
        set -- "$@" $TEST_ARGS
    fi

    if [ -n "${TEST_LIST:-}" ]; then
        set -- "$@" -r "/workspace/$TEST_LIST"
    else
        # Intentional expansion supports paths such as tests/*.phpt.
        # shellcheck disable=SC2086
        set -- "$@" $TEST_PATH
    fi

    # Runner-level PHP arguments must precede the runner script.
    # shellcheck disable=SC2086
    php ${TEST_RUNNER_PHP_ARGS:-} "$TEST_RUNNER" "$@"
}

if [ "${1:-}" = "--inside" ]; then
    inside_container
    exit
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <musl|glibc>" >&2
    exit 2
fi

test_libc=$1
case "$test_libc" in
    musl|glibc) ;;
    *)
        echo "Unsupported test libc: $test_libc" >&2
        exit 2
        ;;
esac

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"
: "${TEST_IMAGE:?TEST_IMAGE must be set}"
: "${TEST_EXTENSION_NAME:?TEST_EXTENSION_NAME must be set}"
: "${TEST_RUNNER:?TEST_RUNNER must be set}"
: "${TEST_PATH:?TEST_PATH must be set}"

# shellcheck source=.github/workflows/scripts/docker-workspace.sh
. "$GITHUB_WORKSPACE/.github/workflows/scripts/docker-workspace.sh"

set -- docker run --rm \
    -e "TEST_LIBC=$test_libc" \
    -e "TEST_PACKAGES=${TEST_PACKAGES:-}" \
    -e "TEST_PRE_COMMAND=${TEST_PRE_COMMAND:-}" \
    -e "TEST_EXTENSION_NAME=$TEST_EXTENSION_NAME" \
    -e "TEST_EXTRA_EXTENSION=${TEST_EXTRA_EXTENSION:-}" \
    -e "TEST_ZEND_EXTENSION=${TEST_ZEND_EXTENSION:-}" \
    -e "TEST_EXTENSION_MODE=${TEST_EXTENSION_MODE:-argument}" \
    -e "TEST_RUNTIME_SETUP_SCRIPT=${TEST_RUNTIME_SETUP_SCRIPT:-}" \
    -e "TEST_INIT_SCRIPT=${TEST_INIT_SCRIPT:-}" \
    -e "TEST_RUNNER=$TEST_RUNNER" \
    -e "TEST_RUNNER_PHP_ARGS=${TEST_RUNNER_PHP_ARGS:-}" \
    -e "TEST_PHP_ARGS=${TEST_PHP_ARGS:-}" \
    -e "TEST_ARGS=${TEST_ARGS:-}" \
    -e "TEST_PATH=$TEST_PATH" \
    -e "TEST_LIST=${TEST_LIST:-}" \
    -v "$DOCKER_WORKSPACE:/workspace" \
    -w /workspace/ext

if [ "$test_libc" = "glibc" ]; then
    set -- "$@" -e DEBIAN_FRONTEND=noninteractive
fi
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    set -- "$@" -e "GITHUB_ACTIONS=$GITHUB_ACTIONS"
fi
if [ -n "${TEST_PHPT:-}" ]; then
    set -- "$@" -e "PHPT=$TEST_PHPT"
fi
if [ -n "${TEST_HOME:-}" ]; then
    set -- "$@" -e "HOME=$TEST_HOME"
fi

set -- "$@" "$TEST_IMAGE" \
    sh /workspace/.github/workflows/scripts/run-extension-tests.sh --inside

exec "$@"
