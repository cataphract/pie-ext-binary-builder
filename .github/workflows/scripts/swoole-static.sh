#!/bin/sh

set -eu

# Swoole 6.x always links OpenSSL, and the anylibc artifact must not retain
# dependencies on Alpine shared libraries. Put static OpenSSL archives in a
# dedicated directory that is passed first through LDFLAGS.
apk add --no-cache -q openssl-dev openssl-libs-static

sh "${GITHUB_WORKSPACE}/.github/workflows/scripts/brotli-static.sh"

mkdir -p /usr/local/static-link
cp /usr/lib/libssl.a /usr/lib/libcrypto.a /usr/local/static-link/

# php-minimal deliberately omits ext-sockets. Swoole only needs its public
# header at build time; the test runtimes load their native sockets extension.
php_version=$(php-config --version)
php_include_dir=$(php-config --include-dir)
mkdir -p "$php_include_dir/ext/sockets"
wget -qO "$php_include_dir/ext/sockets/php_sockets.h" \
    "https://raw.githubusercontent.com/php/php-src/php-${php_version}/ext/sockets/php_sockets.h"
