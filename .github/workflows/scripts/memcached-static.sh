#!/bin/sh


set -eu

open_shell() {
  sh -i
}
trap open_shell ERR

ALPINE_VER=$(cat /etc/alpine-release | cut -d. -f1,2)

apk add --no-cache -q abuild git flex

abuild-keygen -a -n 2>/dev/null
install -m 644 /root/.abuild/*.pub /etc/apk/keys/ 2>/dev/null || true

git clone --no-checkout --depth 1 \
    -b "${ALPINE_VER}-stable" \
    https://gitlab.alpinelinux.org/alpine/aports.git /tmp/aports
cd /tmp/aports
git sparse-checkout init --cone
git sparse-checkout set \
    main/libmemcached main/libevent
git checkout

pkg_srcdir() {
  set -x
    local pkg="$1" dir="/tmp/aports/main/$1"
    local srcdir="${dir}/src" pkgname= _pkgver= pkgver= builddir=
    cd "$dir"
    abuild -F fetch unpack prepare >/dev/null 2>&1
    eval "$(grep -E '^(pkgname|_pkgver|pkgver|builddir)=' APKBUILD | head -4)"
    echo "${builddir:-${srcdir}/${pkgname}-${pkgver}}"
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
  -DCMAKE_INSTALL_PREFIX=/usr ..
make -j"$(nproc)" && make install

#MUSL_CLANG=/usr/local/bin/musl-clang
#mv "$MUSL_CLANG" "${MUSL_CLANG}.orig"
#cat > "$MUSL_CLANG" << 'WRAPPER_EOF'
##!/bin/sh
#shared=0
#for a; do case "$a" in -shared) shared=1 ;; esac; done
#[ "$shared" = "0" ] && exec "${0}.orig" "$@"
#
#args=
#for a; do
#    case "$a" in
#        -ljpeg|-lpng16|-llzma|-lxml2|-lz|-lfreetype|-lbz2)
#            args="$args -Wl,-Bstatic $a -Wl,-Bdynamic" ;;
#        *) args="$args $a" ;;
#    esac
#done
#set -x
#exec "${0}.orig" -v $args
#WRAPPER_EOF
#chmod +x "$MUSL_CLANG"
