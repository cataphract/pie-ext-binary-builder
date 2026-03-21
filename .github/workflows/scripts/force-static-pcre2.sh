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
if [ ! -f "$PCRE2LIB_DIR/pcre2.h" ]; then
    mkdir -p "$PCRE2LIB_DIR"
    cat > "$PCRE2LIB_DIR/pcre2.h" << 'HDR_EOF'
/* Redirect to the system PCRE2 header for anylibc compat builds. */
#ifndef PCRE2_CODE_UNIT_WIDTH
# define PCRE2_CODE_UNIT_WIDTH 8
#endif
#include <pcre2.h>
HDR_EOF
    echo "==> pcre2lib/pcre2.h stub installed."
else
    echo "==> pcre2lib/pcre2.h already exists (bundled PCRE2), skipping stub."
fi

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
     * RTLD_DEEPBIND (used by PHP to load extensions) affects even
     * dlsym(RTLD_DEFAULT, ...) for symbols defined in apcu.so: it finds
     * apcu.so's own stubs instead of PHP binary's exports.
     *
     * pcre2_match_8 is NOT defined in apcu.so, so dlsym(RTLD_DEFAULT, ...)
     * for it is unaffected by RTLD_DEEPBIND.  It is present in the global
     * scope only when PHP uses an external libpcre2 (DT_NEEDED dependency).
     *
     * For bundled-PCRE2 PHP, use dlopen(NULL, ...) to obtain a handle to
     * the main executable and resolve php_pcre2_* directly from there,
     * bypassing the RTLD_DEEPBIND local scope entirely.
     */
    void *pcre2_match_direct = dlsym(RTLD_DEFAULT, "pcre2_match_8");

    if (pcre2_match_direct) {
        /* External PCRE2: pcre2_*_8 are already in the global scope
         * via PHP binary's DT_NEEDED on libpcre2-8.so.0. */
#define X(name) _pcre2_compat_##name##_fn = dlsym(RTLD_DEFAULT, "pcre2_" #name "_8");
        PCRE2_SYMS
#undef X
    } else {
        /* Bundled PCRE2: php_pcre2_* are exported by the PHP binary.
         * dlopen(NULL, RTLD_LAZY) opens the main executable; dlsym on
         * that handle searches the main program directly, not apcu.so's
         * local scope, so RTLD_DEEPBIND does not redirect the lookup. */
        void *main_handle = dlopen(NULL, RTLD_LAZY);
        if (main_handle) {
#define X(name) _pcre2_compat_##name##_fn = dlsym(main_handle, "php_pcre2_" #name);
            PCRE2_SYMS
#undef X
        }
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

/*
 * sigsetjmp replacement for anylibc builds.
 *
 * musl's sigsetjmp (statically linked into the .so) is:
 *   push %rbp; mov %rsp,%rbp; call __sigsetjmp@plt; pop %rbp; ret
 * The extra frame corrupts the rbp that glibc's __sigsetjmp saves in the
 * jmp_buf.  When glibc's siglongjmp restores that rbp the caller's
 * stack frame is trashed, leading to SIGSEGV (apc_entry_003).
 *
 * The linker --wrap=sigsetjmp option (applied in the musl-clang wrapper
 * below) redirects every call to sigsetjmp → __wrap_sigsetjmp here.
 * This stub is a direct tail-call to __sigsetjmp with no extra frame,
 * matching glibc's own sigsetjmp = "jmp __sigsetjmp".
 */
    .globl  __wrap_sigsetjmp
    .hidden __wrap_sigsetjmp
    .type   __wrap_sigsetjmp, @function
__wrap_sigsetjmp:
    jmp     __sigsetjmp@plt
    .size   __wrap_sigsetjmp, . - __wrap_sigsetjmp
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
    # --wrap=sigsetjmp redirects every call to sigsetjmp → __wrap_sigsetjmp,
    # which is a bare "jmp __sigsetjmp@plt" stub in libpcre2_compat.a.
    # This avoids musl's statically-linked sigsetjmp wrapper (push rbp;
    # call __sigsetjmp; pop rbp) that corrupts the jmp_buf rbp when glibc's
    # siglongjmp later restores it, trashing the caller's stack frame.
    exec "${0}.orig" "$@" -Wl,--wrap=sigsetjmp /tmp/libpcre2_compat.a
else
    exec "${0}.orig" "$@"
fi
WRAPPER_EOF
chmod +x "$MUSL_CLANG"
echo "==> musl-clang wrapper installed."
