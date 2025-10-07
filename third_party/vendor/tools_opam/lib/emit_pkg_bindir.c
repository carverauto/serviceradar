#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>             /* access */

#include "utarray.h"
#include "utstring.h"

#include "liblogc.h"

#include "emit_pkg_bindir.h"

#define DEBUG_LEVEL coswitch_debug
extern int  DEBUG_LEVEL;
#define TRACE_FLAG coswitch_trace
extern bool TRACE_FLAG;

/* static int level = 0; */
extern int spfactor;
extern char *sp;

#if defined(PROFILE_dev)
extern int indent;
extern int delta;
#endif

/* bool stdlib_root = false; */

/* char *buildfile_prefix = "@//" HERE_OBAZL_ROOT "/buildfiles"; */
/* was: "@//.opam.d/buildfiles"; */

/* long *KPM_TABLE; */

/* FILE *opam_resolver; */

extern UT_string *repo_name;

/* FIXME: same in mibl/error_handler.c */
void _emit_opam_pkg_bindir(UT_string *dst_dir,
                           char *switch_pfx,
                           char *coswitch_lib,
                           const char *pkg
                          )
{
    (void)coswitch_lib;
    TRACE_ENTRY;
    LOG_DEBUG(0, "switch_pfx: %s", switch_pfx);
    /* read dune-package file. if it exports executables:
       1. write bin/BUILD.bazel with a rule for each
       2. symlink from opam switch
     */
    UT_string *dune_pkg_file;
    utstring_new(dune_pkg_file);
    utstring_printf(dune_pkg_file, "%s/lib/%s/dune-package",
                    switch_pfx, /* global */
                    pkg);

    //FIXME: verify access
    LOG_DEBUG(0, "dune-pkg: %s", utstring_body(dune_pkg_file));

    dune_package_open(utstring_body(dune_pkg_file));
    UT_array *executables = dune_package_files_fld("bin");
    if (utarray_len(executables) == 0) {
        LOG_DEBUG(0, "No executables found for pkg '%s'", pkg);
        goto stublibs;
    }

    /* if executables not null:
       1. create 'bin' subdir of pkg
       2. symlink executables to <pkg>/bin
       3. add BUILD.bazel with exports_files for linked executables
     */

    UT_string *outpath;
    utstring_new(outpath);
    UT_string *opam_bin;
    utstring_new(opam_bin);

    errno = 0;
    utstring_new(outpath);
    utstring_printf(outpath,
                    "%s/bin",
                    utstring_body(dst_dir));
                    /* "%s/opam.%s/bin", */
                    /* coswitch_lib, */
                    /* pkg); */
    mkdir_r(utstring_body(outpath));

    /* create <pkg>/bin/BUILD.bazel */
    utstring_renew(outpath);
    utstring_printf(outpath,
                    "%s/bin/BUILD.bazel",
                    utstring_body(dst_dir));
                    /* "%s/opam.%s/bin/BUILD.bazel", */
                    /* coswitch_lib, */
                    /* pkg); */
    /* rc = access(utstring_body(build_bazel_file), F_OK); */
    LOG_DEBUG(0, "fopening: %s", utstring_body(outpath));

    errno = 0;
    FILE *ostream;
    ostream = fopen(utstring_body(outpath), "w");
    if (ostream == NULL) {
        printf(RED "ERROR" CRESET "fopen failure for %s", utstring_body(outpath));
        log_error("fopen failure for %s", utstring_body(outpath));
        perror(utstring_body(outpath));
        log_error("Value of errno: %d", errno);
        log_error("fopen error %s", strerror( errno ));
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "## generated file - DO NOT EDIT\n");

    fprintf(ostream, "exports_files([");

    /* For each executable, create symlink and exports_files entry */
    char **p = NULL;
    while ( (p=(char**)utarray_next(executables,p))) {
        LOG_DEBUG(0, "bin: %s",*p);
        fprintf(ostream, "\"%s\",", *p);
        /* symlink */
        utstring_renew(opam_bin);
        utstring_printf(opam_bin,
                        "%s/bin/%s",
                        switch_pfx,
                        /* utstring_body(switch_bin), */
                        *p);
        LOG_DEBUG(2, "SYMLINK SRC: %s", utstring_body(opam_bin));
        utstring_renew(outpath);
        utstring_printf(outpath,
                        "%s/bin/%s",
                        utstring_body(dst_dir),
                        *p);
                        /* "%s/opam.%s/bin/%s", */
                        /* coswitch_lib, */
                        /* pkg, */
                        /* *p); */
        LOG_DEBUG(2, "SYMLINK DST: %s", utstring_body(outpath));
        int rc = symlink(utstring_body(opam_bin),
                     utstring_body(outpath));
        symlink_ct++;
        if (rc != 0) {
            if (errno != EEXIST) {
                perror(NULL);
                fprintf(stderr, "exiting\n");
                exit(EXIT_FAILURE);
            }
        }
    }
    fprintf(ostream, "])\n");
    fclose(ostream);

    if (verbose && verbosity > 1) {
        utstring_renew(outpath);
        utstring_printf(outpath,
                        "%s/bin", utstring_body(dst_dir));
                        /* "%s/opam.%s/bin", */
                        /* coswitch_lib, */
                        /* pkg); */
        LOG_INFO(0, "Created %s containing symlinked pkg executables",
                 utstring_body(outpath));
    }


 stublibs:
    ;
    // FIXME: get stublibs dir from opam_switch_stublibs()?
    /* opam dumps all stublibs ('dllfoo.so') in lib/stublibs; they are
       not found in the pkg's lib subdir. But the package's
       dune-package file lists them, so we read that and then symlink
       them from lib/stublibs to lib/<pkg>/stublibs.
     */

    UT_array *stublibs = dune_package_files_fld("stublibs");
    dune_package_close();
    if (utarray_len(stublibs) == 0) {
        LOG_DEBUG(0, "NO STUBLIBS for %s", pkg);
        goto finished;
    }

    UT_string *opam_stublib;
    utstring_new(opam_stublib);

    errno = 0;
    utstring_new(outpath);
    utstring_printf(outpath,
                    "%s/stublibs",
                    utstring_body(dst_dir));
                    /* coswitch_lib, */
                    /* pkg); */
    mkdir_r(utstring_body(outpath));
    /* LOG_DEBUG(0, "stublibs: %s", utstring_body(outpath)); */
    utstring_renew(outpath);
    utstring_printf(outpath,
                    "%s/stublibs/BUILD.bazel",
                    utstring_body(dst_dir));
                    /* coswitch_lib, */
                    /* pkg); */
    /* rc = access(utstring_body(build_bazel_file), F_OK); */
    LOG_DEBUG(1, "fopening: %s", utstring_body(outpath));

    /* FILE *ostream; */
    errno = 0;
    ostream = fopen(utstring_body(outpath), "w");
    if (ostream == NULL) {
        printf(RED "ERROR" CRESET "fopen failure for %s", utstring_body(outpath));
        log_error("fopen failure for %s", utstring_body(outpath));
        perror(utstring_body(outpath));
        log_error("Value of errno: %d", errno);
        log_error("fopen error %s", strerror( errno ));
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "## generated file - DO NOT EDIT\n");

    fprintf(ostream, "exports_files([");

    /* For each stublib, create symlink and exports_files entry */
    p = NULL;
    while ( (p=(char**)utarray_next(stublibs,p))) {
        LOG_DEBUG(0, "stublib: %s",*p);
        fprintf(ostream, "\"%s\",", *p);
        /* symlink */
        utstring_renew(opam_stublib);
        utstring_printf(opam_stublib,
                        "%s/lib/stublibs/%s",
                        switch_pfx,
                        *p);
        LOG_DEBUG(1, "symlink src: %s", utstring_body(opam_stublib));
        utstring_renew(outpath);
        utstring_printf(outpath,
                        "%s/stublibs/%s",
                        utstring_body(dst_dir),
                        /* coswitch_lib, */
                        /* pkg, */
                        *p);
        LOG_DEBUG(1, "symlink dst: %s", utstring_body(outpath));
        int rc = symlink(utstring_body(opam_stublib),
                     utstring_body(outpath));
        symlink_ct++;
        if (rc != 0) {
            if (errno != EEXIST) {
                perror(NULL);
                fprintf(stderr, "ERROR,exiting\n");
                exit(EXIT_FAILURE);
            }
        }
    }
    fprintf(ostream, "])\n");
    fclose(ostream);

    if (verbose && verbosity > 1) {
        utstring_renew(outpath);
        utstring_printf(outpath,
                        "%s/stublibs",
                        utstring_body(dst_dir));
                        /* coswitch_lib, */
                        /* pkg); */

        LOG_INFO(0, "Created %s containing symlinked stublibs",
                 utstring_body(outpath));
    }

finished:
    ;
    TRACE_EXIT;
    /* utstring_free(outpath); */
}

UT_string *dune_pkg_file;

/* pkg always relative to (global) opam_switch_lib */
EXPORT void emit_pkg_bindir(UT_string *dst_dir,
                            char *opam_switch_pfx,
                            char *coswitch_lib,
                            const char *pkg)
{
    TRACE_ENTRY;
    LOG_TRACE(0, "emit_pkg_bindir: %s", pkg);

    utstring_renew(dune_pkg_file);
    utstring_printf(dune_pkg_file,
                    "%s/lib/%s/dune-package",
                    opam_switch_pfx, /* global */
                    pkg);

    LOG_DEBUG(0, "CHECKING DUNE-PACKAGE: %s", utstring_body(dune_pkg_file));
    if (access(utstring_body(dune_pkg_file), F_OK) == 0) {
        _emit_opam_pkg_bindir(dst_dir,
                              opam_switch_pfx,
                              coswitch_lib,
                              pkg);
    } else {
        /* FIXME: handle error */
    }
}
