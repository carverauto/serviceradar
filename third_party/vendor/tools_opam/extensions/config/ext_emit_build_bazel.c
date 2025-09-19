#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fnmatch.h>
#include <glob.h>
#include <libgen.h>
/* #include <regex.h> */

#if EXPORT_INTERFACE
#include <stdio.h>
#endif

#ifdef __linux__
#include <linux/limits.h>
#else
#include <limits.h>
#endif
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cwalk.h"
#include "liblogc.h"
#include "utarray.h"
#include "utstring.h"

#include "findlibc.h"

#include "ext_emit_build_bazel.h"

extern int level;
extern int spfactor;
extern char *sp;

extern int log_writes;
extern int log_symlinks;

#define DEBUG_LEVEL debug_tools_opam
extern int  DEBUG_LEVEL;
#define TRACE_FLAG trace_tools_opam
extern bool TRACE_FLAG;
extern int indent;
extern int delta;

extern bool verbose;
extern int debug;
extern bool trace;

UT_string *bzl_switch_pfx;
UT_string *bazel_pkg_root;

extern char *default_version;
extern int   default_compat;
extern char *bazel_compat;

extern char *switch_pfx;
extern char *switch_lib;

EXPORT void xmkdir_r(const char *dir) {
    /* log_debug("xmkdir_r %s", dir); */
    char tmp[512];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp),"%s",dir);
    len = strlen(tmp);
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    for (p = tmp + 1; *p; p++)
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, S_IRWXU);
            *p = '/';
        }
    mkdir(tmp, S_IRWXU);
}

/* ******************************** */
EXPORT char *_opam_root(void)
{
    TRACE_ENTRY;

#define BUFSZ 512
    char buf[BUFSZ];
    /* char *result = NULL; */
    char *exe = "opam";
    /* char *argv[] = {"opam", "var", "root", NULL}; */
    /* result = run_cmd(exe, argv); */
    /* if (result == NULL) { */
    /*     fprintf(stderr, "FAIL: run_cmd 'opam var root'\n"); */
    /* } */
    /* return result; */

    char *argv[] = {
        "opam", "var", "root",
        NULL
    };

    int argc = (sizeof(argv) / sizeof(argv[0])) - 1;
    int stdout_pipe;
    int stderr_pipe;
    FILE *stdoutstream = NULL;
    FILE *stderrstream = NULL;
    errno = 0;
    int result = spawn_cmd(exe, argc, argv, &stdout_pipe, &stderr_pipe);
    /* result = spawn_cmd_with_stdout(exe, argc, argv); */
    if (result != 0) {
        fprintf(stderr, "FAIL: spawn_cmd\n");
        exit(EXIT_FAILURE);
    } else {
        if (errno == 2) {
            LOG_ERROR(0, "ERRNO 2", "");
        } else if (errno != 0) {
            LOG_INFO(0, "cmd rc: %d", errno);
        }
        LOG_DEBUG(0, "getting spawn output", "");
        errno = 0;
        stdoutstream = fdopen(stdout_pipe, "r");
        if (stdoutstream == NULL) {
            /* Handle error */
            log_error("fdopen failure on pipe", "");
            perror(NULL);
            return NULL;
        } else {
            /* #if defined(PROFILE_fastbuild) */
            /*         log_debug("fdopened pipe", ""); */
            /* #endif */
        }

        /* char *pkg_name; */
        while (fgets(buf, BUFSZ, stdoutstream)) {
            /* if dotted, print only first seg */
            buf[strcspn(buf, "\n")] = 0;
            if (strlen(buf) == 0) continue;

            LOG_DEBUG(0, "res: %s", buf);
        }
        fclose(stdoutstream);
        /* now stderr */
        errno = 0;
        stderrstream = fdopen(stderr_pipe, "r");
        if (stderrstream == NULL) {
            /* Handle error */
            log_error("fdopen failure on pipe", "");
            perror(NULL);
            return NULL;
        } else {
            /* #if defined(PROFILE_fastbuild) */
            /*         log_debug("fdopened pipe", ""); */
            /* #endif */
        }

        /* char *pkg_name; */
        while (fgets(buf, BUFSZ, stderrstream)) {
            fprintf(stderr, "%s", buf);
        }

        fclose(stderrstream);
    }
    close(stdout_pipe);
    close(stderr_pipe);
    return strdup(buf);
}

EXPORT void ext_emit_module_file(UT_string *module_file,
                                 struct obzl_meta_package *_pkg,
                                 bool alias)
{
    TRACE_ENTRY_MSG("%s", _pkg->name);
    LOG_DEBUG(0, "module file: %s", utstring_body(module_file));
    findlib_version_t *semv;
    char version[256];
    semv = findlib_pkg_version(_pkg);
    sprintf(version, "%d.%d.%d",
            semv->major, semv->minor, semv->patch);

    FILE *ostream;
    ostream = fopen(utstring_body(module_file), "w");
    if (ostream == NULL) {
        LOG_ERROR(0, "fopen fail: %s %s",
                  utstring_body(module_file),
                  strerror(errno));
        perror(utstring_body(module_file));
        exit(EXIT_FAILURE);
    }

    fprintf(ostream, "## generated file - DO NOT EDIT\n\n");

    fprintf(ostream, "module(\n");
    if (alias) {
        fprintf(ostream, "    name = \"%s\",\n", _pkg->module_name);
    } else {
        fprintf(ostream, "    name = \"opam.%s\",\n", _pkg->module_name);
    }
    fprintf(ostream, "    version = \"%s\",  # %s\n",
            default_version, version);
    fprintf(ostream, "    compatibility_level = %d, # %d\n",
            default_compat, semv->major);
    fprintf(ostream, "    bazel_compatibility = [\">=%s\"]\n",
            bazel_compat);
    fprintf(ostream, ")\n");
    fprintf(ostream, "\n");

    /* opam bzlmodules depend on ocaml_import */
    /* if (!alias) { */
    fprintf(ostream, "bazel_dep(name = \"rules_ocaml\", version = \"%s\")\n", rules_ocaml_version);
    /* } */
    /* modules that depend on built-ins, e.g. str, threads, unix, etc. */
    LOG_DEBUG(0, "running findlib", "");
    UT_array *pkg_deps = findlib_pkg_deps(_pkg, true);
    if (pkg_deps == NULL) {
        LOG_DEBUG(0, "pkg has no deps", "");
        fprintf(ostream, "\n");
        fclose(ostream);
        TRACE_EXIT;
        return;
    }
    LOG_DEBUG(0, "pkg deps ct: %d", utarray_len(pkg_deps));
    char **p = NULL;
    if (!alias) {
        if (pkg_deps) {
            while ( (p=(char**)utarray_next(pkg_deps, p))) {
                if ((strncmp(*p, "compiler-libs", 13) == 0)
                    || (strncmp(*p, "dynlink", 7) == 0)
                    || (strncmp(*p, "ocamldoc", 8) == 0)
                    || (strncmp(*p, "str", 3) == 0)
                    || (strncmp(*p, "threads", 7) == 0)
                    || (strncmp(*p, "unix", 4) == 0)
                    ){
                    fprintf(ostream, "bazel_dep(name = \"ocamlsdk\",       version = \"%s\")\n", ocaml_version);
                    break;
                }
            }
        }
        /* fprintf(ostream, "          version = \"0.0.0\")\n"); */
        fprintf(ostream, "\n");

        // get **repo** deps: direct deps of pkg and all subpkgs
        if (pkg_deps) {
            p = NULL;
            /* struct obzl_meta_package *pkg; */
            /* LOG_DEBUG(0, "HASH CT: %d", HASH_COUNT(_pkgs)); */
            while ( (p=(char**)utarray_next(pkg_deps, p))) {
                LOG_DEBUG(0, "pkg dep: %s", *p);
                if ((strncmp(*p, "compiler-libs", 13) == 0)
                    || (strncmp(*p, "dynlink", 7) == 0)
                    || (strncmp(*p, "ocamldoc", 8) == 0)
                    || (strncmp(*p, "str", 3) == 0)
                    || (strncmp(*p, "threads", 7) == 0)
                    || (strncmp(*p, "unix", 4) == 0)
                    ){
                    continue;
                }
                if (strncmp(*p, _pkg->name, 512) != 0) {
                    /* for now ignore actual versions */
                    sprintf(version, "%d.%d.%d", 0,0,0);
                    /* HASH_FIND_STR(_pkgs, *p, pkg); */
                    /* if (pkg) { */
                    /*     free(semv); */
                    /*     version[0] = '\0'; */
                    /*     semv = findlib_pkg_version(pkg); */
                    /*     sprintf(version, "%d.%d.%d", */
                    /*             semv->major, semv->minor, semv->patch); */
                    /* } else { */
                    /*     //FIXME: pkg 'compiler-libs' (a dep of */
                    /*     // ppxlib.astlib etc.) is a pseudo-pkg, */
                    /*     // referring to lib/ocaml/compiler-libs, */
                    /*     // so it has neither pkg entry nor version */
                    /*     if (strncmp(*p, "compiler-libs", 13) == 0) { */
                    /*         sprintf(version, "%d.%d.%d", 0,0,0); */
                    /*     } else { */
                    /*         sprintf(version, "%d.%d.%d", -1, -1 , -1); */
                    /*     } */
                    /* } */
                    fprintf(ostream, "bazel_dep(name = \"%s\", version = \"%s\")\n",
                            *p, default_version);
                    /* fprintf(ostream, "bazel_dep(name = \"opam.%s\", version = \"%s\") # %s\n", */
                    /*         *p, default_version, version); */
                    /* fprintf(ostream, "          version = \"%s\")\n", */
                    /*         default_version); */
                }
            }
        }
    }
    /* HACK ALERT! This hideous code deals with ppx_runtime_deps,
       and must check to prevent duplicates.
     */
    char **already = NULL;      /* for searching */
    if (pkg_deps) {
        utarray_sort(pkg_deps,strsort);
    }
    UT_array *pkg_codeps = findlib_pkg_codeps(_pkg, true);
    if (pkg_codeps) {
        char **p = NULL;
        /* struct obzl_meta_package *pkg; */
        /* LOG_DEBUG(0, "HASH CT: %d", HASH_COUNT(_pkgs)); */
        /* exit(0); */
        while ( (p=(char**)utarray_next(pkg_codeps, p))) {
            if (strncmp(*p, _pkg->name, 512) != 0) {
                sprintf(version, "%d.%d.%d", 0,0,0);
                /* HASH_FIND_STR(_pkgs, *p, pkg); */
                /* if (pkg) { */
                /*     free(semv); */
                /*     version[0] = '\0'; */
                /*     semv = findlib_pkg_version(pkg); */
                /*     sprintf(version, "%d.%d.%d", */
                /*             semv->major, semv->minor, semv->patch); */
                /* } else { */
                /*     //FIXME: pkg 'compiler-libs' (a dep of */
                /*     // ppxlib.astlib etc.) is a pseudo-pkg, */
                /*     // referring to lib/ocaml/compiler-libs, */
                /*     // so it has neither pkg entry nor version */
                /*     if (strncmp(*p, "compiler-libs", 13) == 0) { */
                /*         sprintf(version, "%d.%d.%d", 0,0,0); */
                /*     } else { */
                /*         sprintf(version, "%d.%d.%d", -1, -1 , -1); */
                /*     } */
                /* } */
                if (pkg_deps) {
                    already = NULL;
                    already = (char**)utarray_find(pkg_deps, p, strsort);
                    if (already == NULL) {
                        fprintf(ostream, "bazel_dep(name = \"%s\", version = \"%s\")\n",
                                *p, default_version);
                        /* fprintf(ostream, "bazel_dep(name = \"%s\", # %s\n", */
                        /*         *p, version); */
                        /* fprintf(ostream, "          version = \"%s\") #codep\n", */
                        /*         default_version); */
                    }
                }
            }
        }
    }

    fprintf(ostream, "\n");

    fclose(ostream);
    if (verbosity > log_writes) {
        fprintf(INFOFD, GRN "INFO" CRESET
                " wrote: %s\n", utstring_body(module_file));
    }
    if (pkg_deps) {
        utarray_free(pkg_deps);
    }
    if (pkg_codeps) {
        utarray_free(pkg_codeps);
    }
    TRACE_EXIT;
}

/* ############################################### */
void ext_emit_ocamlsdk_module(char *_ocaml_version,
                              char *switch_pfx,
                              char *obazl_pfx)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "switch_pfx: %s", switch_pfx);

    /* for the sdk, we are only interested in the sdk_lib,
       which is the lib/ subdir of the effective switch (either
       opam or system). if switch uses the system-compiler,
       then we find that lib; otherwise we use $switch_pfx/lib.

       if switch uses system-compiler, we need both the
       system bin/ and the switch bin. otherwise just the
       switch bin.
     */

    char *switch_bin;
    char *sdk_lib = getenv("OBAZL_SDKLIB");
    char *sdk_bin = NULL;
    LOG_DEBUG(0, "SDKLIB: %s", sdk_lib);

    UT_string *work;
    utstring_new(work);
    utstring_printf(work,
                    "%s/bin",
                    switch_pfx);
    switch_bin = strdup(utstring_body(work));
    utstring_renew(work);
    if (sdk_lib == NULL) {
        utstring_printf(work,
                        "%s/lib",
                        switch_pfx);
        sdk_lib = strdup(utstring_body(work));
        /* utstring_new(work); */
        /* utstring_printf(work, */
        /*                 "%s/bin", */
        /*                 switch_pfx); */
        /* sdk_bin = strdup(utstring_body(work)); */
    } else {
        /* switch uses system-compiler */
        /* cwk_path_get_dirname(sdk_lib, &len); */
        char *p = strrchr(sdk_lib, '/');
        int len = p - sdk_lib;
        /* LOG_DEBUG(0, "len: %d", len); */
        char buf[len];
        memcpy(buf, sdk_lib, len); // includes the '/'
        buf[len] = '\0';           // replace the '/'
        LOG_DEBUG(0, "buf: %s", buf);
        UT_string *_sdkbin;
        utstring_new(_sdkbin);
        utstring_printf(_sdkbin,
                        "%s/bin",
                        buf);
        sdk_bin = utstring_body(_sdkbin);
    }
    LOG_DEBUG(0, "switch_bin: %s", switch_bin);
    LOG_DEBUG(0, "sdk_bin: %s", sdk_bin);
    LOG_DEBUG(0, "sdk_lib: %s", sdk_lib);

    char *coswitch_lib = "lib";

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file, "MODULE.bazel");
    FILE *ostream = fopen(utstring_body(dst_file), "w");
    if (ostream == NULL) {
        log_error("%s", strerror(errno));
        perror(utstring_body(dst_file));
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "## generated file - DO NOT EDIT\n\n");
    fprintf(ostream, "module(\n");
    fprintf(ostream, "    name = \"ocamlsdk\", version = \"%s\",\n", ocaml_version);
    fprintf(ostream, "    compatibility_level = %d,\n", default_compat);
    fprintf(ostream, "    bazel_compatibility = [\">=%s\"]\n", bazel_compat);
    fprintf(ostream, ")\n");
    fprintf(ostream, "\n");
    fprintf(ostream,
            "bazel_dep(name = \"platforms\", version = \"%s\")\n", platforms_version);
    fprintf(ostream,
            "bazel_dep(name = \"bazel_skylib\", version = \"%s\")\n", skylib_version);
    fprintf(ostream,
            "bazel_dep(name = \"rules_ocaml\", version = \"%s\")\n", rules_ocaml_version);

    /* fprintf(ostream, */
    /*         "bazel_dep(name = \"stublibs\", version = \"%s\")\n", */
    /*         default_version); */

    fclose(ostream);
    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET
                " wrote %s\n", utstring_body(dst_file));

    UT_string *bld_file;
    utstring_new(bld_file);
    utstring_printf(bld_file, "bin");
    mkdir_r(utstring_body(bld_file));
    utstring_printf(bld_file, "/BUILD.bazel");
    emit_ocaml_bin_build_file(utstring_body(bld_file));

    UT_string *dst_dir;
    utstring_new(dst_dir);
    utstring_printf(dst_dir, "bin");
    emit_ocaml_bin_symlinks(dst_dir, switch_bin);
    if (sdk_bin != NULL) {
        emit_ocaml_sdkbin_symlinks(dst_dir, sdk_bin);
    }
    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "toolchain");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_toolchain_buildfiles(obazl_pfx, dst_dir);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "config");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_config_pkg(obazl_pfx,
                          dst_dir,
                          sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "stdlib/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_stdlib_pkg(dst_dir, sdk_lib);

    /* SPECIAL CASE: lib/ocaml/expunge
       This is an executable used to build toplevel repls */
    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "bin");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_expunge(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "stublibs/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_stublibs(dst_dir, sdk_lib);

    //  <switch>lib/stublibs: not an ocamlsdk subdir,
    // must be installed separately
    /* char *switch_stublibs = opam_switch_stublibs(switch_id); */
    /* emit_lib_stublibs_pkg(NULL, switch_stublibs, coswitch_lib); */

    // aliases <switch>lib/compiler-libs:
    /* NB: under opam_dep extension this must
       be built as a distinct dep
     */
    /* emit_compiler_libs_pkg(NULL, coswitch_lib); */

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "compiler-libs");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_compiler_libs_pkg(obazl_pfx, dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "bigarray/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_bigarray_pkg(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "dynlink/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_dynlink_pkg(dst_dir, sdk_lib);

    /* num lib split out of core distrib starting 4.06.0 */
    /* emit_ocaml_num_pkg(NULL, sdk_lib, coswitch_lib); */

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "ocamldoc/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_ocamldoc_pkg(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "profiling/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_profiling_pkg(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "runtime_events/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_rtevents_pkg(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "str/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_str_pkg(dst_dir, sdk_lib);

    //NB: vmthreads removed in v. 4.08.0?
    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "threads/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_threads_pkg(dst_dir, sdk_lib);
    /* if (!ocaml_prev5) */
        /* emit_registry_record(registry, compiler_version, */
        /*                      NULL, pkgs); */

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "unix/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_unix_pkg(dst_dir, sdk_lib);

    /* this is an obazl invention: */
    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "runtime");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_runtime_pkg(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "ffi/lib");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_c_ffi_pkg(dst_dir, sdk_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir, "version");
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_version(dst_dir, coswitch_lib, _ocaml_version);

    TRACE_EXIT;
}
