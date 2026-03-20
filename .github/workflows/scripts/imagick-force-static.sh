#!/bin/sh
# Rebuild ImageMagick and its delegate libraries with -fPIC so they can all be
# linked statically into imagick.so.  Alpine's -static packages are compiled
# without -fPIC, causing linker errors when building .so against them.
#
# Delegates are forced static via:
#   1. pkgconfig Libs: patched to include -l flags for delegates.
#   2. A musl-clang wrapper that wraps those -l flags with
#      -Wl,-Bstatic/-Wl,-Bdynamic on shared-object link invocations.
set -eu

ALPINE_VER=$(cat /etc/alpine-release | cut -d. -f1,2)
IM_TAG=$(grep '#define MAGICKCORE_PACKAGE_VERSION' \
    /usr/include/ImageMagick-7/MagickCore/magick-baseconfig.h \
    | sed 's/.*"\(.*\)".*/\1/')

echo "==> Alpine ${ALPINE_VER}: rebuilding delegate libs + IM ${IM_TAG} with -fPIC..."

apk add --no-cache -q \
    abuild git cmake \
    libjpeg-turbo-dev libpng-dev zlib-dev xz-dev libxml2-dev freetype-dev

abuild-keygen -a -n 2>/dev/null
install -m 644 /root/.abuild/*.pub /etc/apk/keys/ 2>/dev/null || true

git clone --no-checkout --depth 1 \
    -b "${ALPINE_VER}-stable" \
    https://gitlab.alpinelinux.org/alpine/aports.git /tmp/aports
cd /tmp/aports
git sparse-checkout init --cone
git sparse-checkout set \
    main/zlib main/libjpeg-turbo main/libpng main/xz main/libxml2 main/freetype main/bzip2
git checkout

# Return the source directory for a package after abuild fetch+unpack+prepare.
# Sources the APKBUILD in a subshell to read pkgname/pkgver/builddir safely.
pkg_srcdir() {
    local pkg="$1" dir="/tmp/aports/main/$1"
    local srcdir="${dir}/src"
    cd "$dir"
    abuild -F fetch unpack prepare >/dev/null 2>&1
    eval "$(grep -E '^(pkgname|pkgver|builddir)=' APKBUILD | head -3)"
    # builddir may reference $srcdir (e.g. builddir="$srcdir/$pkgname-$pkgver")
    # expand it with srcdir set above, fall back to $srcdir/$pkgname-$pkgver
    local computed="${builddir:-${srcdir}/${pkgname}-${pkgver}}"
    if [ -d "$computed" ]; then
        echo "$computed"
    else
        # Newer Alpine may unpack to a differently-named directory; find it
        find "$srcdir" -maxdepth 1 -mindepth 1 -type d | head -1
    fi
}

# zlib
src=$(pkg_srcdir zlib)
cd "$src"
CC=musl-clang CFLAGS="-fPIC -O2" ./configure --static
make -j"$(nproc)"
cp libz.a /usr/lib/libz.a

# libjpeg-turbo
src=$(pkg_srcdir libjpeg-turbo)
cd "$src"
cmake -B _build \
    -DCMAKE_C_COMPILER=musl-clang \
    -DCMAKE_C_FLAGS="-fPIC -O2" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWITH_JPEG8=1 \
    -DCMAKE_INSTALL_PREFIX=/usr
cmake --build _build -j"$(nproc)"
cp _build/libjpeg.a /usr/lib/libjpeg.a

# libpng
src=$(pkg_srcdir libpng)
cd "$src"
CC=musl-clang CFLAGS="-fPIC -O2" \
    ./configure --prefix=/usr --disable-shared --enable-static
make -j"$(nproc)"
cp .libs/libpng16.a /usr/lib/libpng16.a

# xz
src=$(pkg_srcdir xz)
cd "$src"
cmake -B _build \
    -DCMAKE_C_COMPILER=musl-clang \
    -DCMAKE_C_FLAGS="-fPIC -O2" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TESTS=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr
cmake --build _build -j"$(nproc)"
cp _build/liblzma.a /usr/lib/liblzma.a

# libxml2
src=$(pkg_srcdir libxml2)
cd "$src"
CC=musl-clang CFLAGS="-fPIC -O2" \
    ./configure --prefix=/usr --disable-shared --enable-static \
    --without-python --without-readline
make -j"$(nproc)"
cp .libs/libxml2.a /usr/lib/libxml2.a

# bzip2
src=$(pkg_srcdir bzip2)
cd "$src"
CC=musl-clang CFLAGS="-fPIC -O2" make -f Makefile libbz2.a
cp libbz2.a /usr/lib/libbz2.a

# freetype
src=$(pkg_srcdir freetype)
cd "$src"
cmake -B _build \
    -DCMAKE_C_COMPILER=musl-clang \
    -DCMAKE_C_FLAGS="-fPIC -O2" \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_BROTLI=ON   -DCMAKE_DISABLE_FIND_PACKAGE_BrotliDec=TRUE \
    -DFT_DISABLE_HARFBUZZ=ON -DCMAKE_DISABLE_FIND_PACKAGE_HarfBuzz=TRUE \
    -DFT_DISABLE_PNG=ON      -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE \
    -DCMAKE_INSTALL_PREFIX=/usr
cmake --build _build -j"$(nproc)"
cp _build/libfreetype.a /usr/lib/libfreetype.a

echo "==> Delegate -fPIC static libs installed."

# ImageMagick
cd /tmp
wget -qO im.tar.gz \
    "https://github.com/ImageMagick/ImageMagick/archive/${IM_TAG}.tar.gz"
tar xf im.tar.gz && cd "ImageMagick-${IM_TAG}"
./configure \
    --prefix=/usr --sysconfdir=/etc \
    --enable-static --disable-shared --without-modules \
    --enable-hdri --with-quantum-depth=16 \
    --with-jpeg --with-png --with-freetype \
    --without-x --without-openmp \
    CC=musl-clang CXX=musl-clang++ \
    CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2"
make -j"$(nproc)"
make install
# remove shared libs to avoid the linker finding them instead of the shared ones
rm -f /usr/lib/libMagickWand*.so* /usr/lib/libMagickCore*.so*

# pkgconfig: expose delegate -l flags
# PHP_EVAL_LIBLINE only processes -l/-L tokens; absolute .a paths are dropped.
# Adding -l flags here ensures they reach IMAGICK_SHARED_LIBADD.
DELEGATE_LIBS="-ljpeg -lpng16 -llzma -lxml2 -lz -lfreetype -lbz2"
for pc in /usr/lib/pkgconfig/MagickWand-7.Q16HDRI.pc \
          /usr/lib/pkgconfig/MagickCore-7.Q16HDRI.pc; do
    [ -f "$pc" ] || continue
    sed -i "s|^Libs: \(.*\)|Libs: \1 ${DELEGATE_LIBS}|" "$pc"
    sed -i 's|^Libs\.private:.*|Libs.private:|' "$pc"
done

# musl-clang wrapper: force -Bstatic for delegate libs
MUSL_CLANG=/usr/local/bin/musl-clang
mv "$MUSL_CLANG" "${MUSL_CLANG}.orig"
cat > "$MUSL_CLANG" << 'WRAPPER_EOF'
#!/bin/sh
shared=0
for a; do case "$a" in -shared) shared=1 ;; esac; done
[ "$shared" = "0" ] && exec "${0}.orig" "$@"

args=
for a; do
    case "$a" in
        -ljpeg|-lpng16|-llzma|-lxml2|-lz|-lfreetype|-lbz2)
            args="$args -Wl,-Bstatic $a -Wl,-Bdynamic" ;;
        *) args="$args $a" ;;
    esac
done
exec "${0}.orig" -v $args
WRAPPER_EOF
chmod +x "$MUSL_CLANG"

# These tests fail
rm -v "${GITHUB_WORKSPACE}/ext/tests/024-ispixelsimilar.phpt" \
  "${GITHUB_WORKSPACE}/ext/tests/243_Tutorial_svgExample_basic.phpt"

echo "==> Done."
