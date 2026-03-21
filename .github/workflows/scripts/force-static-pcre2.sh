#!/bin/sh
# Build a static compatibility library for APCu anylibc builds.
#
# APCu (compiled with -DHAVE_BUNDLED_PCRE) calls php_pcre2_* symbols.
# PHP may be built with bundled PCRE2 (exporting php_pcre2_*) or with
# external libpcre2 (not exporting php_pcre2_*).  Because PHP loads
# extensions with RTLD_DEEPBIND, simple forwarding stubs cannot be
# preempted by PHP binary symbols.
#
# Solution: assembly stubs jump through function pointers that are
# resolved at DSO load time by a constructor using dlsym:
#   - If dlsym(RTLD_DEFAULT, "php_pcre2_match") resolves outside our
#     DSO → PHP has bundled PCRE2 → bind all stubs to PHP's php_pcre2_*
#   - Otherwise → PHP has external PCRE2 → bind stubs to pcre2_*_8
#     (already in the global scope via PHP's own DT_NEEDED on libpcre2)
set -eu

# ── 1. Fake pcre2lib/pcre2.h ─────────────────────────────────────────────────
# When HAVE_BUNDLED_PCRE is defined, php_pcre.h includes "pcre2lib/pcre2.h"
# (PHP's internal copy).  On external-PCRE PHP that file does not exist, so
# we create a redirect that pulls in the installed system header.
PCRE2LIB_DIR=/usr/local/include/php/ext/pcre/pcre2lib
mkdir -p "$PCRE2LIB_DIR"
cat > "$PCRE2LIB_DIR/pcre2.h" << 'HDR_EOF'
/* Redirect to the system PCRE2 header for anylibc compat builds. */
#ifndef PCRE2_CODE_UNIT_WIDTH
# define PCRE2_CODE_UNIT_WIDTH 8
#endif
#include <pcre2.h>
HDR_EOF
echo "==> pcre2lib/pcre2.h stub installed."

# ── 2. C resolver ────────────────────────────────────────────────────────────
cat > /tmp/pcre2_compat_resolve.c << 'C_EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

/*
 * One hidden void* per php_pcre2_* symbol.  "Hidden" lets the assembler
 * reference them via direct RIP-relative addressing (no GOT needed).
 */
#define PCRE2_SYMS \
    X(callout_enumerate) \
    X(code_copy) \
    X(code_copy_with_tables) \
    X(code_free) \
    X(compile) \
    X(compile_context_copy) \
    X(compile_context_create) \
    X(compile_context_free) \
    X(config) \
    X(convert_context_copy) \
    X(convert_context_create) \
    X(convert_context_free) \
    X(dfa_match) \
    X(general_context_copy) \
    X(general_context_create) \
    X(general_context_free) \
    X(get_error_message) \
    X(get_mark) \
    X(get_ovector_count) \
    X(get_ovector_pointer) \
    X(get_startchar) \
    X(jit_compile) \
    X(jit_free_unused_memory) \
    X(jit_match) \
    X(jit_stack_assign) \
    X(jit_stack_create) \
    X(jit_stack_free) \
    X(maketables) \
    X(match) \
    X(match_context_copy) \
    X(match_context_create) \
    X(match_context_free) \
    X(match_data_create) \
    X(match_data_create_from_pattern) \
    X(match_data_free) \
    X(pattern_info) \
    X(serialize_decode) \
    X(serialize_encode) \
    X(serialize_free) \
    X(serialize_get_number_of_codes) \
    X(set_bsr) \
    X(set_callout) \
    X(set_character_tables) \
    X(set_compile_extra_options) \
    X(set_compile_recursion_guard) \
    X(set_depth_limit) \
    X(set_glob_escape) \
    X(set_glob_separator) \
    X(set_heap_limit) \
    X(set_match_limit) \
    X(set_max_pattern_length) \
    X(set_newline) \
    X(set_offset_limit) \
    X(set_parens_nest_limit) \
    X(set_recursion_limit) \
    X(set_recursion_memory_management) \
    X(substitute) \
    X(substring_copy_byname) \
    X(substring_copy_bynumber) \
    X(substring_free) \
    X(substring_get_byname) \
    X(substring_get_bynumber) \
    X(substring_length_byname) \
    X(substring_length_bynumber) \
    X(substring_list_free) \
    X(substring_list_get) \
    X(substring_nametable_scan) \
    X(substring_number_from_name)

#define X(name) __attribute__((visibility("hidden"))) void *_pcre2_compat_##name##_fn;
PCRE2_SYMS
#undef X

__attribute__((constructor))
static void pcre2_compat_resolve(void)
{
    /*
     * Determine our own DSO path so we can detect whether
     * dlsym(RTLD_DEFAULT, "php_pcre2_match") found PHP's copy or our stub.
     */
    static const char _anchor = 0;
    Dl_info self_info = {0};
    dladdr((void *)&_anchor, &self_info);

    /*
     * Probe: if php_pcre2_match lives in a different file than us, the PHP
     * binary exports it (bundled PCRE2) → use php_pcre2_* for everything.
     * Otherwise PHP has external PCRE2 and doesn't export php_pcre2_* →
     * use pcre2_*_8 (available in the global scope from PHP's libpcre2 dep).
     */
    int use_php = 0;
    {
        void *probe = dlsym(RTLD_DEFAULT, "php_pcre2_match");
        if (probe) {
            Dl_info fi = {0};
            dladdr(probe, &fi);
            if (fi.dli_fname && self_info.dli_fname &&
                strcmp(fi.dli_fname, self_info.dli_fname) != 0)
                use_php = 1;
        }
    }

    if (use_php) {
#define X(name) _pcre2_compat_##name##_fn = dlsym(RTLD_DEFAULT, "php_pcre2_" #name);
        PCRE2_SYMS
#undef X
    } else {
#define X(name) _pcre2_compat_##name##_fn = dlsym(RTLD_DEFAULT, "pcre2_" #name "_8");
        PCRE2_SYMS
#undef X
    }
}
C_EOF

# ── 3. Assembly stubs ─────────────────────────────────────────────────────────
# Each stub is a global php_pcre2_NAME that tail-calls through the function
# pointer _pcre2_compat_NAME_fn resolved by the constructor above.
# Hidden visibility on the pointers allows direct RIP-relative addressing.
cat > /tmp/pcre2_compat.s << 'ASM_EOF'
    .text

.macro pcre2_compat name
    .globl  php_pcre2_\name
    .type   php_pcre2_\name, @function
php_pcre2_\name:
    jmp     *_pcre2_compat_\name\()_fn(%rip)
    .size   php_pcre2_\name, . - php_pcre2_\name
.endm

    pcre2_compat callout_enumerate
    pcre2_compat code_copy
    pcre2_compat code_copy_with_tables
    pcre2_compat code_free
    pcre2_compat compile
    pcre2_compat compile_context_copy
    pcre2_compat compile_context_create
    pcre2_compat compile_context_free
    pcre2_compat config
    pcre2_compat convert_context_copy
    pcre2_compat convert_context_create
    pcre2_compat convert_context_free
    pcre2_compat dfa_match
    pcre2_compat general_context_copy
    pcre2_compat general_context_create
    pcre2_compat general_context_free
    pcre2_compat get_error_message
    pcre2_compat get_mark
    pcre2_compat get_ovector_count
    pcre2_compat get_ovector_pointer
    pcre2_compat get_startchar
    pcre2_compat jit_compile
    pcre2_compat jit_free_unused_memory
    pcre2_compat jit_match
    pcre2_compat jit_stack_assign
    pcre2_compat jit_stack_create
    pcre2_compat jit_stack_free
    pcre2_compat maketables
    pcre2_compat match
    pcre2_compat match_context_copy
    pcre2_compat match_context_create
    pcre2_compat match_context_free
    pcre2_compat match_data_create
    pcre2_compat match_data_create_from_pattern
    pcre2_compat match_data_free
    pcre2_compat pattern_info
    pcre2_compat serialize_decode
    pcre2_compat serialize_encode
    pcre2_compat serialize_free
    pcre2_compat serialize_get_number_of_codes
    pcre2_compat set_bsr
    pcre2_compat set_callout
    pcre2_compat set_character_tables
    pcre2_compat set_compile_extra_options
    pcre2_compat set_compile_recursion_guard
    pcre2_compat set_depth_limit
    pcre2_compat set_glob_escape
    pcre2_compat set_glob_separator
    pcre2_compat set_heap_limit
    pcre2_compat set_match_limit
    pcre2_compat set_max_pattern_length
    pcre2_compat set_newline
    pcre2_compat set_offset_limit
    pcre2_compat set_parens_nest_limit
    pcre2_compat set_recursion_limit
    pcre2_compat set_recursion_memory_management
    pcre2_compat substitute
    pcre2_compat substring_copy_byname
    pcre2_compat substring_copy_bynumber
    pcre2_compat substring_free
    pcre2_compat substring_get_byname
    pcre2_compat substring_get_bynumber
    pcre2_compat substring_length_byname
    pcre2_compat substring_length_bynumber
    pcre2_compat substring_list_free
    pcre2_compat substring_list_get
    pcre2_compat substring_nametable_scan
    pcre2_compat substring_number_from_name
ASM_EOF

musl-clang -c /tmp/pcre2_compat_resolve.c -o /tmp/pcre2_compat_resolve.o
musl-clang -c /tmp/pcre2_compat.s -o /tmp/pcre2_compat.o
ar rcs /tmp/libpcre2_compat.a /tmp/pcre2_compat_resolve.o /tmp/pcre2_compat.o
echo "==> libpcre2_compat.a built."

# ── 4. Wrap musl-clang ────────────────────────────────────────────────────────
MUSL_CLANG=/usr/local/bin/musl-clang
mv "$MUSL_CLANG" "${MUSL_CLANG}.orig"
cat > "$MUSL_CLANG" << 'WRAPPER_EOF'
#!/bin/sh
is_compile=0
is_shared=0
for a; do
    case "$a" in
        -c)      is_compile=1 ;;
        -shared) is_shared=1  ;;
    esac
done
if [ "$is_compile" = "1" ]; then
    exec "${0}.orig" "$@" -DHAVE_BUNDLED_PCRE
elif [ "$is_shared" = "1" ]; then
    exec "${0}.orig" "$@" /tmp/libpcre2_compat.a
else
    exec "${0}.orig" "$@"
fi
WRAPPER_EOF
chmod +x "$MUSL_CLANG"
echo "==> musl-clang wrapper installed."
