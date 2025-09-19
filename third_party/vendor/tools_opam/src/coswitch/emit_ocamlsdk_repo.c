#include <errno.h>
#include <dirent.h>
#ifdef __linux__
#include <linux/limits.h>
#else
#include <limits.h>
#endif
/* #if EXPORT_INTERFACE */
#include <stdio.h>
/* #endif */
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "liblogc.h"
#include "findlibc.h"
#include "utarray.h"
#if EXPORT_INTERFACE
#include "utstring.h"
#endif

#include "emit_ocamlsdk_repo.h"

extern int verbosity;
extern int log_writes;
extern int log_symlinks;

extern char *default_version;
extern int   default_compat;
extern char *bazel_compat;

extern UT_string *opam_ocaml_version;

#define DEBUG_LEVEL coswitch_debug
extern int  DEBUG_LEVEL;
#define TRACE_FLAG coswitch_trace
extern bool TRACE_FLAG;
extern bool coswitch_debug_symlinks;

/*
  src: an opam <switch>/lib dir
  dst: same as src
      or XDG_DATA_HOME/obazl/opam/<switch>/
      or project-local _opam/
  bootstrap_FILE: remains open so opam pkgs can write to it
 */
EXPORT void emit_ocamlsdk_module(UT_string *registry,
                                 char *compiler_version,
                                 struct obzl_meta_package *pkgs,
                                 char *switch_name,
                                 char *switch_pfx,
                                 char *coswitch_lib,
                                 char *obazl_pfx,
                                 char *runfiles)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "switch_name: %s", switch_name);
    LOG_TRACE(0, BLU "EMIT_ocaml_workspace:" CRESET
              " switch_pfx:%s, dst: %s",
              switch_pfx, coswitch_lib);

    char *switch_lib = opam_switch_lib(switch_name);

    /* this emits reg record for both ocaml and stublibs pkgs */
    emit_registry_record(registry, compiler_version, NULL, pkgs);

    UT_string *dst_file;
    utstring_new(dst_file);
    /* utstring_concat(dst_file, coswitch_lib); // pfx); */
    utstring_printf(dst_file, "%s/ocamlsdk", coswitch_lib);
    mkdir_r(utstring_body(dst_file));

    // now MODULE.bazel
    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/ocamlsdk/MODULE.bazel",
                    coswitch_lib);
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

    fprintf(ostream,
            "bazel_dep(name = \"stublibs\", version = \"%s\")\n",
            default_version);

    fclose(ostream);
    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET
                " wrote %s\n", utstring_body(dst_file));

    utstring_renew(dst_file);
    utstring_printf(dst_file, "%s/ocamlsdk", coswitch_lib);

    UT_string *bld_file;
    utstring_new(bld_file);
    utstring_printf(bld_file, "%s/ocamlsdk/bin", coswitch_lib);
    mkdir_r(utstring_body(bld_file));
    utstring_printf(bld_file, "/BUILD.bazel");
    emit_ocaml_bin_dir(utstring_body(bld_file));

    UT_string *dst_dir;
    utstring_new(dst_dir);
    utstring_printf(dst_dir, "%s/ocamlsdk/bin", coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    _emit_ocaml_bin_symlinks(dst_dir, switch_pfx); //, coswitch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/toolchain",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_toolchain_buildfiles(obazl_pfx, dst_dir);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/stdlib",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_stdlib_pkg(obazl_pfx, dst_dir, switch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/stublibs",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_stublibs(dst_dir, switch_pfx);

    // for <switch>lib/stublibs:
    char *switch_stublibs = opam_switch_stublibs(switch_name);
    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/stublibs",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_lib_stublibs_pkg(dst_dir,
                          switch_stublibs);
    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/compiler-libs",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_compiler_libs_pkg(dst_dir,
                                 switch_lib);

    /* Bigarray integrated into stdlib as of 4.07 */
    emit_ocaml_bigarray_pkg(runfiles, switch_lib, coswitch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/dynlink",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_dynlink_pkg(dst_dir, switch_lib);

    /* num lib split out of core distrib starting 4.06.0 */
    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/num",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_num_pkg(dst_dir, switch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/ocamldoc",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_ocamldoc_pkg(dst_dir, switch_lib);

    // 5.0.0+ has <switch>/lib/ocaml/profiling/META
    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/profiling",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_profiling_pkg(dst_dir, switch_lib); //, coswitch_lib);
    // pre-5.0.0: no <switch>/lib/ocaml/profiling
    // always emit <coswitch>/lib/ocaml/profiling
    /* emit_ocaml_profiling_alias_pkg(dst_dir, switch_lib, coswitch_lib); */

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/runtime_events",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_rtevents_pkg(dst_dir, switch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/str",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_str_pkg(dst_dir, switch_lib);

    //NB: vmthreads removed in v. 4.08.0?
    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/threads",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_threads_pkg(dst_dir, switch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/unix",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_unix_pkg(dst_dir, switch_lib);

    /* this is an obazl invention: */
    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/runtime",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_runtime_pkg(dst_dir, switch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/lib/ffi",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    emit_ocaml_c_ffi_pkg(dst_dir, switch_lib);

    utstring_renew(dst_dir);
    utstring_printf(dst_dir,
                    "%s/ocamlsdk/version",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));
    /* emit_ocaml_version(dst_dir, coswitch_lib, compiler_version); */

    utstring_free(dst_dir);

    TRACE_EXIT;
}
