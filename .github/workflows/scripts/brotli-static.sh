#!/bin/sh

# Alpine's brotli-static archives (>= 1.2.0-r0) are GCC slim-LTO objects:
# lld silently skips them (symbols stay undefined in the produced .so) and
# GNU ld needs the GCC LTO plugin. Rebuild brotli from source with the musl
# clang toolchain so real static archives, headers and .pc files are
# available for the extension build.

set -eux

apk add --no-cache -q cmake make git

git clone --depth 1 -b v1.1.0 https://github.com/google/brotli.git /tmp/brotli
cd /tmp/brotli
mkdir out
cd out
CC=musl-clang cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib
make -j"$(nproc)"
make install

# The .pc files only list the split library; static linking also needs
# libbrotlicommon, and extension configure scripts call pkg-config without
# --static, so append it to the public Libs line.
sed -i '/^Libs:/s/$/ -lbrotlicommon/' \
    /usr/lib/pkgconfig/libbrotlidec.pc /usr/lib/pkgconfig/libbrotlienc.pc
