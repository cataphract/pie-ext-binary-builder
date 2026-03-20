#!/bin/sh

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

echo "==> PCRE2 ${VER} static lib installed."

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
        -lpcre2-8)
            args="$args -Wl,--push-state -Wl,-Bstatic $a -Wl,--pop-state" ;;
        *) args="$args $a" ;;
    esac
done
exec "${0}.orig" -v $args
WRAPPER_EOF
chmod +x "$MUSL_CLANG"

echo "==> musl-clang wrapper installed."

exec sh -i
