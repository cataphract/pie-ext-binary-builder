#!/bin/sh


set -eu

open_shell() {
  sh -i
}
trap open_shell ERR

ALPINE_VER=$(cat /etc/alpine-release | cut -d. -f1,2)

apk add --no-cache -q abuild git flex cyrus-sasl-dev cyrus-sasl-static

abuild-keygen -a -n 2>/dev/null
install -m 644 /root/.abuild/*.pub /etc/apk/keys/ 2>/dev/null || true

git clone --no-checkout --depth 1 \
    -b "${ALPINE_VER}-stable" \
    https://gitlab.alpinelinux.org/alpine/aports.git /tmp/aports
cd /tmp/aports
git sparse-checkout init --cone
git sparse-checkout set \
    main/libmemcached main/libevent main/cyrus-sasl
git checkout

pkg_srcdir() {
    local pkg="$1" dir="/tmp/aports/main/$1"
    local srcdir="${dir}/src"
    if [ ! -f "${dir}/APKBUILD" ]; then
        echo "==> ERROR: APKBUILD missing for ${pkg} at ${dir}" >&2
        exit 1
    fi
    cd "$dir"
    mkdir -p /var/cache/distfiles
    if ! abuild -F deps fetch unpack prepare >"/tmp/abuild_${pkg}.log" 2>&1; then
        echo "==> ERROR: abuild failed for ${pkg}:" >&2
        cat "/tmp/abuild_${pkg}.log" >&2
        exit 1
    fi
    eval "$(grep -E '^(pkgname|_pkgver|pkgver|builddir)=' APKBUILD | head -4)"
    local computed="${builddir:-${srcdir}/${pkgname}-${pkgver}}"
    if [ -d "$computed" ]; then
        echo "$computed"
    else
        local found
        found=$(find "$srcdir" -maxdepth 1 -mindepth 1 -type d | head -1)
        if [ -z "$found" ]; then
            echo "==> ERROR: no source dir found for ${pkg} (computed: ${computed})" >&2
            cat "/tmp/abuild_${pkg}.log" >&2
            exit 1
        fi
        echo "$found"
    fi
}


set -x
# libevent
cd "$(pkg_srcdir libevent)"
CFLAGS="-fPIC -O2 -fno-omit-frame-pointer" ./configure \
  --enable-static --disable-shared --prefix=/usr
make -j"$(nproc)" && make install

# libmemcached
cd "$(pkg_srcdir libmemcached)"
mkdir Release
cd Release
cmake -DCMAKE_TOOLCHAIN_FILE=/sysroot/$(arch)-none-linux-musl/Toolchain.cmake  \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_SASL=ON \
  -DCMAKE_INSTALL_PREFIX=/usr ..
make -j"$(nproc)" && make install

# hashkit is a separate static archive from the cmake build; the php-memcached
# extension links libmemcached via pkg-config and won't see -lhashkit unless
# we add it explicitly.
# -lc++ -lc++abi: libmemcached is C++; the PHP extension build uses musl-clang
# (C wrapper) for the final link, so C++ runtime symbols must be added
# explicitly here.
sed -i '/^Libs:/s/$/ -lhashkit -lsasl2 -lc++ -lc++abi/' /usr/lib/pkgconfig/libmemcached.pc

# cyrus-sasl: rebuild with -fPIC (the APK static package is compiled without it).
# abuild deps installs heimdal-dev, gdbm-dev, etc. needed for the full plugin set.
src=$(pkg_srcdir cyrus-sasl)
cd "$src"
# Build core library only — no static plugins compiled in.
# When plugins are compiled into libsasl2.a and linked into a .so, the linker
# creates dynamic relocations for the function pointers in _sasl_static_plugins
# instead of pulling the plugin objects from the archive, leaving the symbols
# undefined at runtime.  With no static plugins the array is just a sentinel,
# memcached.so loads cleanly, and SASL mechanism plugins are loaded at runtime
# from /usr/lib/sasl2/ on the target system.
CC=musl-clang CFLAGS="-fPIC -O2" ./configure \
    --prefix=/usr --sysconfdir=/etc \
    --enable-static --disable-shared \
    --with-plugindir=/usr/lib/sasl2 \
    --with-dblib=none \
    --disable-krb4 --disable-gssapi --disable-krb5 \
    --disable-scram --disable-cram --disable-digest \
    --disable-ntlm --disable-otp --disable-auth-sasldb \
    --disable-anon --disable-plain --disable-login \
    --without-pwcheck --with-devrandom=/dev/urandom \
    --disable-sample
# lib/Makefile has a libsasl2.a target that bundles the core lib + static plugin
# objects (compiled from symlinked plugin sources with STATIC_* defines).
# Build common first (lib depends on libplugin_common.la), then build all of lib
# so the BUILT_SOURCES / linksrcs mechanism runs and libsasl2.a gets assembled.
make -j"$(nproc)" -C common
make -j"$(nproc)" -C lib
# lib/Makefile uses 'ar cru' to add plugin objects but doesn't ranlib afterwards;
ranlib lib/.libs/libsasl2.a
cp lib/.libs/libsasl2.a /usr/lib/libsasl2.a
rm -f /usr/lib/libsasl2.so /usr/lib/libsasl2.so.*

# igbinary php extension
git clone -q --depth 1 -b 3.2.16 \
    https://github.com/igbinary/igbinary /tmp/igbinary
cd /tmp/igbinary
phpize >/dev/null 2>&1
CC=musl-clang ./configure --enable-igbinary >/dev/null 2>&1
make -j"$(nproc)" >/dev/null 2>&1
mkdir -p "${GITHUB_WORKSPACE}/ext/modules"
cp modules/igbinary.so "${GITHUB_WORKSPACE}/ext/modules/igbinary.so"
patchelf --remove-needed "libc.musl-$(uname -m).so.1" \
    "${GITHUB_WORKSPACE}/ext/modules/igbinary.so" 2>/dev/null || true
PHPINCDIR=$(php-config --include-dir)
mkdir -p "$PHPINCDIR/ext/igbinary/src/php7"
cp igbinary.h "$PHPINCDIR/ext/igbinary/"
cp src/php7/igbinary.h "$PHPINCDIR/ext/igbinary/src/php7/"

