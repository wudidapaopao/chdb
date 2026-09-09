if (GLIBC_COMPATIBILITY)
    enable_language(ASM)

    add_headers_and_sources(glibc_compatibility .)
    add_headers_and_sources(glibc_compatibility musl)
    if (ARCH_AARCH64)
        list (APPEND glibc_compatibility_sources musl/aarch64/syscall.s musl/aarch64/longjmp.s)
        set (musl_arch_include_dir musl/aarch64)
        # Disable getauxval in aarch64. ARM glibc minimum requirement for the project is 2.18 and getauxval is present
        # in 2.16. Having a custom one introduces issues with sanitizers
        list (REMOVE_ITEM glibc_compatibility_sources musl/getauxval.c)
    elseif (ARCH_AMD64)
        list (APPEND glibc_compatibility_sources musl/x86_64/syscall.s musl/x86_64/longjmp.s)
        set (musl_arch_include_dir musl/x86_64)
    else ()
        message (FATAL_ERROR "glibc_compatibility can only be used on x86_64 or aarch64.")
    endif ()

    # chdb, static-library build only: glibc's posix_spawn, not this directory's. The
    # in-tree one is a partial reimplementation that drops file actions
    # (musl/posix_spawn.c explains why it cannot walk them). That is harmless inside a
    # binary or a shared library - the two callers in this tree pass no file actions, and
    # chdb/libchdb_export.map makes the symbol local in libchdb.so. It is not harmless in
    # libchdb.a, which is handed to a linker chdb does not control: the archive's strong
    # definition displaces libc's for whatever program links it, so a consumer's
    # dup2/chdir/close requests vanish with no error returned (chdb-io/chdb-core#216).
    #
    # Scoped rather than unconditional, because the shared build does need these. Nothing
    # in chdb's own sources calls posix_spawn_file_actions_add{,f}chdir_np, but the Rust
    # crates the wheel links (ENABLE_RUST=1) do, and glibc versions those at 2.29 - above
    # the 2.17 floor manylinux2014 allows. Dropping them everywhere pushed the wheel to
    # GLIBC_2.29 and auditwheel refused to repair it. The static build sets ENABLE_RUST=0
    # and references nothing above posix_spawn's own 2.15, so it can do without them.
    #
    # One decision in two halves, because the family is split across musl/posix_spawn.c
    # (posix_spawn) and glibc-compatibility.c (posix_spawnp, posix_spawn_file_actions_*).
    # Never take one half alone: chdb's posix_spawn_file_actions_* build a musl fdop list
    # in a field glibc's posix_spawn reads as a counted __spawn_action array, so mixing
    # the two walks garbage instead of merely ignoring it.
    if (CHDB_STATIC_LIBRARY_BUILD)
        list (REMOVE_ITEM glibc_compatibility_sources musl/posix_spawn.c)
    endif ()

    if (SANITIZE STREQUAL thread AND ARCH_AMD64)
        # Disable TSAN instrumentation that conflicts with re-exec due to high ASLR entropy using getauxval
        # See longer comment in __auxv_init_procfs
        # In the case of tsan we need to make sure getauxval is not instrumented as that would introduce tsan
        # internal calls to functions that depend on a state that isn't initialized yet
        set_source_files_properties(
                musl/getauxval.c
                PROPERTIES COMPILE_FLAGS "-mllvm -tsan-instrument-func-entry-exit=false")
    endif()

    # Need to omit frame pointers to match the performance of glibc
    set (CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fomit-frame-pointer")

    add_library(glibc-compatibility STATIC ${glibc_compatibility_sources})

    target_no_warning(glibc-compatibility unused-command-line-argument)
    target_no_warning(glibc-compatibility unused-but-set-variable)
    target_no_warning(glibc-compatibility builtin-requires-header)

    target_include_directories(glibc-compatibility PRIVATE libcxxabi ${musl_arch_include_dir})

    if (CHDB_STATIC_LIBRARY_BUILD)
        target_compile_definitions(glibc-compatibility PRIVATE CHDB_NO_POSIX_SPAWN_COMPAT)
    endif ()

    if (ENABLE_OPENSSL_DYNAMIC)
        target_compile_options(glibc-compatibility PRIVATE -fPIC)
    endif ()

    target_link_libraries(global-libs INTERFACE glibc-compatibility)

    message (STATUS "Some symbols from glibc will be replaced for compatibility")

elseif (CLICKHOUSE_OFFICIAL_BUILD)
    message (WARNING "Option GLIBC_COMPATIBILITY must be turned on for production builds.")
endif ()
