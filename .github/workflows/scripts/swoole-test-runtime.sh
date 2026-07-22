#!/bin/sh

set -eu

case "${TEST_LIBC:?TEST_LIBC must be set}" in
    musl)
        # PHPIZE_DEPS is a package list supplied by the official PHP image.
        # shellcheck disable=SC2086
        apk add --no-cache -q $PHPIZE_DEPS linux-headers
        ;;
    glibc)
        apt-get update -q
        # PHPIZE_DEPS is a package list supplied by the official PHP image.
        # shellcheck disable=SC2086
        apt-get install -y -q $PHPIZE_DEPS linux-libc-dev procps
        ;;
    *)
        echo "Unsupported test libc: $TEST_LIBC" >&2
        exit 2
        ;;
esac

docker-php-ext-install -j2 sockets pcntl

extension_dir=$(php-config --extension-dir)
cp "/workspace/ext/modules/${TEST_EXTENSION_NAME:?}.so" \
    "$extension_dir/$TEST_EXTENSION_NAME.so"
docker-php-ext-enable "$TEST_EXTENSION_NAME"
