#!/bin/sh
# Build PCRE2 with -fPIC as a static lib and remove the shared lib symlink so
# that extensions link PCRE2 statically, embedding it in the .so.  This avoids
# a runtime dependency on the host's libpcre2-8.so.0 version.
set -eu

VER=$(apk info pcre2 2>/dev/null | head -1 | sed 's/pcre2-\([0-9.]*\).*/\1/')
echo "==> Building PCRE2 ${VER} static -fPIC..."

apk add --no-cache -q wget

wget -qO /tmp/pcre2.tar.gz \
    "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${VER}/pcre2-${VER}.tar.gz"
tar -C /tmp -xf /tmp/pcre2.tar.gz
cd "/tmp/pcre2-${VER}"

./configure \
    --disable-shared --enable-static \
    --with-match-limit-recursion=MATCH_LIMIT \
    CFLAGS="-fPIC -O2"
make -j"$(nproc)"
cp .libs/libpcre2-8.a /usr/lib/libpcre2-8.a

# Remove the dynamic-link symlink so the linker falls back to the static lib.
# The runtime .so.0 is kept intact for PHP itself.
rm -f /usr/lib/libpcre2-8.so

echo "==> PCRE2 ${VER} static lib installed."
