#include <errno.h>
#include <dirent.h>
#ifdef __linux__
#include <linux/limits.h>
#else
#include <limits.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "liblogc.h"
#include "findlibc.h"
#include "librunfiles.h"
#include "utarray.h"
#if EXPORT_INTERFACE
#include "utstring.h"
#endif

#include "emit_ocamlsdk.h"

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
bool coswitch_debug_symlinks = false;

char *f;
char *rf;

FILE *_open_buildfile(UT_string *ocaml_file)
{
    FILE *ostream = fopen(utstring_body(ocaml_file), "w");
    if (ostream == NULL) {
        log_error("fopen: %s: %s", strerror(errno),
                  utstring_body(ocaml_file));
        fprintf(stderr, "fopen: %s: %s", strerror(errno),
                utstring_body(ocaml_file));
        fprintf(stderr, "exiting\n");
        /* perror(utstring_body(ocaml_file)); */
        exit(EXIT_FAILURE);
    }
    return ostream;
}

EXPORT void emit_ocaml_stdlib_pkg(UT_string *dst_dir,
                                  char *switch_lib)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "dstdir: %s", utstring_body(dst_dir));
    LOG_DEBUG(0, "switch_lib: %s", switch_lib);

    bool add_toplevel = false;

    UT_string *stdlib_dir;
    utstring_new(stdlib_dir);
    utstring_printf(stdlib_dir,
                    "%s/stdlib",
                    switch_lib);
    int rc = access(utstring_body(stdlib_dir), F_OK);
    if (rc != 0) {
        /* if (coswitch_trace) */
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(stdlib_dir));
        utstring_new(stdlib_dir);
        utstring_printf(stdlib_dir,
                        "%s/ocaml/stdlib",
                        switch_lib);
        int rc = access(utstring_body(stdlib_dir), F_OK);
        if (rc != 0) {
            /* if (coswitch_trace) */
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(stdlib_dir));
            utstring_free(stdlib_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET,
                     utstring_body(stdlib_dir));
            add_toplevel = true;
        }
    }

    UT_string *dst_file;
    utstring_new(dst_file);

    // 5.0.0+ has <switch>/lib/ocaml/stdlib/META
    // pre-5.0.0: no <switch>/lib/ocaml/stdlib
    // always emit <coswitch>/lib/ocaml/stdlib
    utstring_printf(dst_file, "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_stdlib_BUILD, */
    /*           ocamlsdk_stdlib_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/stdlib.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    if (add_toplevel) {
        // not found: <switch>/lib/stdlib
        // means >= 5.0.0 (<switch>/lib/ocaml/stdlib)

        // add <coswitch>/lib/stdlib for (bazel) compatibility
    } else {
        // if we found <switch>/lib/stdlib (versions < 5.0.0)
        // then we need to populate <coswitch>/lib/ocaml/stdlib
        // (its already there for >= 5.0.0)
        utstring_new(stdlib_dir);
        utstring_printf(stdlib_dir,
                        "%s/ocaml",
                        switch_lib);
        /* _symlink_ocaml_stdlib(stdlib_dir, */
        /*                        utstring_body(dst_dir)); */
    }

    /* stdlib files are always in <switchpfx>/lib/ocaml
       even for v5
    */
    utstring_renew(stdlib_dir);
    utstring_printf(stdlib_dir,
                    "%s/ocaml",
                    switch_lib);
    _symlink_ocaml_stdlib(stdlib_dir,
                          utstring_body(dst_dir));

    utstring_free(dst_file);
    utstring_free(stdlib_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_stdlib(UT_string *stdlib_srcdir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "srcdir: %s", utstring_body(stdlib_srcdir));
    LOG_DEBUG(0, "tgtdir: %s", tgtdir);

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(stdlib_srcdir));
    if (d == NULL) {
        log_error("Unable to opendir for symlinking stdlib: %s\n",
                  utstring_body(stdlib_srcdir));
        /* exit(EXIT_FAILURE); */
        return;
    }
    LOG_DEBUG(0, "opened dir %s", utstring_body(stdlib_srcdir));

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            if (strncmp("stdlib", direntry->d_name, 6) != 0) {
                if (strncmp("camlinternal",
                            direntry->d_name, 12) != 0) {
                    continue;
                }
            }
            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(stdlib_srcdir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(0, "symlinking %s to %s",
                      srcfile,
                      /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            if (rc != 0) {
                if (errno != EEXIST) {
                    perror(utstring_body(src));
                    fprintf(stderr, "exiting\n");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_expunge(UT_string *dst_dir,
                              char *switch_lib)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "dstdir: %s", utstring_body(dst_dir));
    LOG_DEBUG(0, "switch_lib: %s", switch_lib);

    /* bool add_toplevel = false; */

    UT_string *dst_file;
    utstring_new(dst_file);

    /* stdlib files are always in <switchpfx>/lib/ocaml
       even for v5
    */
    UT_string *stdlib_dir;
    utstring_new(stdlib_dir);
    utstring_printf(stdlib_dir,
                    "%s/ocaml",
                    switch_lib);
    _symlink_ocaml_expunge(stdlib_dir,
                           utstring_body(dst_dir));

    utstring_free(dst_file);
    utstring_free(stdlib_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_expunge(UT_string *stdlib_srcdir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "srcdir: %s", utstring_body(stdlib_srcdir));
    LOG_DEBUG(0, "tgtdir: %s", tgtdir);

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    utstring_renew(src);
    utstring_printf(src, "%s/expunge",
                    utstring_body(stdlib_srcdir));
    static char *srcfile;
    srcfile = realpath(utstring_body(src), NULL);

    utstring_renew(dst);
    utstring_printf(dst, "%s/expunge", tgtdir);

    fprintf(stdout, "symlinking %s to %s\n",
              srcfile,
              /* utstring_body(src), */
              utstring_body(dst));
    fprintf(stderr, "symlinking %s to %s\n",
              srcfile,
              /* utstring_body(src), */
              utstring_body(dst));

    rc = symlink(srcfile, /* utstring_body(src), */
                 utstring_body(dst));
    if (rc != 0) {
        if (errno != EEXIST) {
            perror(utstring_body(src));
            fprintf(stderr, "exiting\n");
            exit(EXIT_FAILURE);
        }
    }
    free(srcfile);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_runtime_pkg(UT_string *dst_dir,
                                   char *switch_lib)
{
    TRACE_ENTRY;
    _symlink_ocaml_runtime_libs(switch_lib, utstring_body(dst_dir));
    _symlink_ocaml_runtime_compiler_libs(switch_lib, utstring_body(dst_dir));

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/BUILD.bazel",
                    utstring_body(dst_dir));

    /* write_buf(ocamlsdk_runtime_BUILD, */
    /*           ocamlsdk_runtime_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/runtime.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);


    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/sys",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/sys/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_runtime_sys_BUILD, */
    /*           ocamlsdk_runtime_sys_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/runtime_sys.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/vm",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/vm/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_runtime_vm_BUILD, */
    /*           ocamlsdk_runtime_vm_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/runtime_vm.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    TRACE_EXIT;
}

/* void _symlink_ocaml_runtime(char *switch_lib, char *tgtdir) */
/* { */
/*     TRACE_ENTRY; */
/*     LOG_DEBUG(0, "rt switchlib: %s", switch_lib); */
/*     LOG_DEBUG(0, "rt tgtdir: %s", tgtdir); */
/*     UT_string *opamdir; */
/*     utstring_new(opamdir); */
/*     utstring_printf(opamdir, "%s/ocaml", */
/*                     switch_lib); */
/*     /\* utstring_body(opam_switch_lib)); *\/ */

/*     UT_string *src; */
/*     utstring_new(src); */
/*     UT_string *dst; */
/*     utstring_new(dst); */
/*     int rc; */

/*     DIR *d = opendir(utstring_body(opamdir)); */
/*     if (d == NULL) { */
/*         perror(utstring_body(opamdir)); */
/*         log_error(RED "Unable to opendir for symlinking stdlib" CRESET); */
/*         exit(EXIT_FAILURE); */
/*         return; */
/*     } */

/*     struct dirent *direntry; */
/*     static char *srcfile; */
/*     while ((direntry = readdir(d)) != NULL) { */
/*         /\* LOG_DEBUG(0, "DIRENT"); *\/ */
/*         if ((direntry->d_type==DT_REG) */
/*             || (direntry->d_type==DT_LNK)) { */
/*             if (strncmp("stdlib", direntry->d_name, 6) != 0) */
/*                 if (strncmp("std_exit", direntry->d_name, 8) != 0) */
/*                     continue; */

/*             utstring_renew(src); */
/*             utstring_printf(src, "%s/%s", */
/*                             utstring_body(opamdir), direntry->d_name); */
/*             srcfile = realpath(utstring_body(src), NULL); */

/*             utstring_renew(dst); */
/*             utstring_printf(dst, "%s/%s", */
/*                             tgtdir, */
/*                             direntry->d_name); */
/*             if (verbosity > log_symlinks) { */
/*                 fprintf(INFOFD, GRN "INFO" CRESET */
/*                         " symlink: %s -> %s\n", */
/*                         srcfile, */
/*                         /\* utstring_body(src), *\/ */
/*                         utstring_body(dst)); */
/*             } */

/*             rc = symlink(srcfile,  /\* utstring_body(src), *\/ */
/*                          utstring_body(dst)); */
/*             symlink_ct++; */
/*             if (rc != 0) { */
/*                 if (errno != EEXIST) { */
/*                     perror(utstring_body(src)); */
/*                     fprintf(stderr, "exiting\n"); */
/*                     exit(EXIT_FAILURE); */
/*                 } */
/*             } */
/*         } */
/*     } */
/*     closedir(d); */
/*     exit(0); */
/*     TRACE_EXIT; */
/* } */

/* ************************************** */
EXPORT void emit_ocaml_stublibs(UT_string *dst_dir,
                                char *switch_pfx)
{
    TRACE_ENTRY;
    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/BUILD.bazel",
                    utstring_body(dst_dir));

    FILE *ostream = fopen(utstring_body(dst_file), "w");
    ostream = fopen(utstring_body(dst_file), "w");
    if (ostream == NULL) {
        perror(utstring_body(dst_file));
        log_error("fopen: %s: %s", strerror(errno),
                  utstring_body(dst_file));
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "# generated file - DO NOT EDIT\n");
    fprintf(ostream,
            "load(\"@bazel_skylib//rules:common_settings.bzl\",\n");
    fprintf(ostream, "     \"string_setting\")\n\n");
    fprintf(ostream,
            "package(default_visibility=[\"//visibility:public\"])\n");
    fprintf(ostream, "exports_files(glob([\"**\"]))\n\n");

    fprintf(ostream,
            "string_setting(name = \"path\",\n");
    fprintf(ostream,
            "               build_setting_default = \"%s/ocaml/stublibs/lib\")\n\n",
            utstring_body(dst_dir)
            );

    fprintf(ostream, "alias(name=\"lib\", actual=\":stublibs\")\n\n");

    fprintf(ostream, "filegroup(\n");
    fprintf(ostream, "    name = \"stublibs\",\n");
    fprintf(ostream, "    srcs = glob([\"dll*\"], allow_empty=True),\n");
    fprintf(ostream, "    data = glob([\"dll*\"], allow_empty=True),\n");
    fprintf(ostream, ")\n");
    fclose(ostream);
    LOG_DEBUG(2, " wrote: %s\n", utstring_body(dst_file));

    _emit_ocaml_stublibs_symlinks(dst_dir,
                                  switch_pfx,
                                  "ocaml/stublibs");
    utstring_free(dst_file);
    TRACE_EXIT;
}

EXPORT void _emit_ocaml_stublibs_symlinks(UT_string *dst_dir,
                                          char *switch_pfx,
                                          /* char *coswitch_lib, */
                                          char *tgtdir)
{
    TRACE_ENTRY;
    UT_string *src_dir;
    utstring_new(src_dir);
    utstring_printf(src_dir,
                    "%s/%s",
                    switch_pfx,
                    tgtdir);

    LOG_DEBUG(1, "stublibs dst_dir: %s", utstring_body(dst_dir));
    LOG_DEBUG(1, "stublibs switch_pfx: %s", switch_pfx);
    LOG_DEBUG(1, "tgtdir: %s", tgtdir);

    UT_string *src;
    utstring_new(src);
    UT_string *dst_file;
    utstring_new(dst_file);
    int rc;

    LOG_DEBUG(1, "opening src_dir for read: %s",
              utstring_body(src_dir));

    DIR *srcd = opendir(utstring_body(src_dir));
    if (srcd == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking stublibs: %s\n",
                utstring_body(src_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(srcd)) != NULL) {
        //Condition to check regular file.
        LOG_DEBUG(1, "stublib: %s, type %d",
                  direntry->d_name, direntry->d_type);
        if( (direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK) ){

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(src_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst_file);
            utstring_printf(dst_file, "%s/%s",
                            utstring_body(dst_dir),
                            direntry->d_name);

            LOG_DEBUG(0, " symlink: %s -> %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst_file));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst_file));
            symlink_ct++;
            if (rc != 0) {
                switch (errno) {
                case EEXIST:
                    goto ignore;
                case ENOENT:
                    log_error("symlink ENOENT: %s", strerror(errno));
                    log_error("a component of '%s' does not name an existing file",  utstring_body(dst_dir));
                    fprintf(stderr, "symlink ENOENT: %s\n", strerror(errno));
                    fprintf(stderr, "A component of '%s' does not name an existing file.\n",  utstring_body(dst_dir));
                    break;
                default:
                    log_error("symlink err: %s", strerror(errno));
                    fprintf(stderr, "symlink err: %s", strerror(errno));
                }
                log_error("Exiting");
                fprintf(stderr, "Error, exiting\n");
                exit(EXIT_FAILURE);
            ignore:
                ;
            }
        }
    }
    closedir(srcd);
    TRACE_EXIT;
}

/**
   <switch>/lib/stublibs - no META file, populated by other pkgs
*/
EXPORT void emit_lib_stublibs_pkg(UT_string *dst_dir,
                                  char *switch_lib)
{
    TRACE_ENTRY;
    UT_string *switch_stublibs_dir;
    utstring_new(switch_stublibs_dir);
    utstring_printf(switch_stublibs_dir,
                    "%s/stublibs",
                    switch_lib);
    /* switch_stublibs); */
    int rc = access(utstring_body(switch_stublibs_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "no stublibs dir found: %s" CRESET,
                 utstring_body(switch_stublibs_dir));
        return;
    }

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/MODULE.bazel",
                    utstring_body(dst_dir));
    FILE *ostream;
    ostream = fopen(utstring_body(dst_file), "w");
    if (ostream == NULL) {
        log_error("%s", strerror(errno));
        perror(utstring_body(dst_file));
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "## generated file - DO NOT EDIT\n\n");
    fprintf(ostream, "module(\n");
    fprintf(ostream, "    name = \"stublibs\", version = \"%s\",\n",
            default_version);
    fprintf(ostream, "    compatibility_level = %d,\n",
            default_compat);
    fprintf(ostream, ")\n");
    fprintf(ostream, "\n");

    fprintf(ostream, "bazel_dep(name = \"rules_ocaml\",");
    fprintf(ostream, " version = \"%s\")\n", rules_ocaml_version);

    fprintf(ostream,
            "bazel_dep(name = \"ocamlsdk\", version = \"%s\")\n", ocaml_version);

    fprintf(ostream,
            "bazel_dep(name = \"bazel_skylib\", version = \"%s\")\n", skylib_version);

    fclose(ostream);
    LOG_DEBUG(2, " wrote: %s\n", utstring_body(dst_file));

    /* now BUILD.bazel */
    utstring_renew(dst_file);
    utstring_printf(dst_file, "%s/lib",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/lib/BUILD.bazel",
                    utstring_body(dst_dir));

    ostream = fopen(utstring_body(dst_file), "w");
    if (ostream == NULL) {
        log_error("fopen: %s: %s", strerror(errno),
                  utstring_body(dst_file));
        fprintf(stderr, "fopen: %s: %s", strerror(errno),
                utstring_body(dst_file));
        fprintf(stderr, "exiting\n");
        /* perror(utstring_body(dst_file)); */
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "# generated file - DO NOT EDIT\n\n");

    fprintf(ostream,
            "load(\"@bazel_skylib//rules:common_settings.bzl\",\n");
    fprintf(ostream, "     \"string_setting\")\n\n");

    fprintf(ostream,
            "package(default_visibility=[\"//visibility:public\"])\n\n");

    fprintf(ostream, "exports_files(glob([\"**\"]))\n\n");

    fprintf(ostream,
            "string_setting(name = \"path\",\n");
    fprintf(ostream,
            "               build_setting_default = \"%s/stublibs/lib\")\n\n",
            utstring_body(dst_dir)
            );

    fprintf(ostream, "alias(name=\"lib\", actual=\":stublibs\")\n\n");
    fprintf(ostream, "filegroup(\n");
    fprintf(ostream, "    name = \"stublibs\",\n");
    fprintf(ostream, "    srcs = glob([\"**\"], allow_empty=True),\n");
    fprintf(ostream, ")\n");
    fclose(ostream);
    LOG_DEBUG(2, " wrote: %s\n", utstring_body(dst_file));

    _emit_lib_stublibs_symlinks(utstring_body(switch_stublibs_dir),
                                utstring_body(dst_dir));

    utstring_free(dst_file);
    TRACE_EXIT;
}

EXPORT void _emit_lib_stublibs_symlinks(char *switch_stublibs,
                                        char *coswitch_lib)
{
    TRACE_ENTRY;
    UT_string *dst_dir;
    utstring_new(dst_dir);
    utstring_printf(dst_dir, "%s/lib",
                    coswitch_lib);
    mkdir_r(utstring_body(dst_dir));

    UT_string *src_dir; // relative to opam_switch_lib
    utstring_new(src_dir);
    utstring_printf(src_dir, "%s", switch_stublibs);

    LOG_DEBUG(1, "libstublibs src_dir: %s\n", utstring_body(src_dir));
    LOG_DEBUG(1, "libstublibs dst_dir: %s\n", utstring_body(dst_dir));

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    LOG_DEBUG(0, "opening src_dir for read: %s",
              utstring_body(src_dir));
    DIR *srcd = opendir(utstring_body(src_dir));
    if (srcd == NULL) {
        log_error("Unable to opendir for symlinking stublibs: %s",
                  utstring_body(src_dir));
        fprintf(stderr, "Unable to opendir for symlinking stublibs: %s\n",
                utstring_body(src_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    while ((direntry = readdir(srcd)) != NULL) {
        //Condition to check regular file.
        LOG_DEBUG(1, "stublib: %s, type %d",
                  direntry->d_name, direntry->d_type);
        if (strncmp(direntry->d_name, "WORKSPACE", 9) == 0) {
            continue;
        }

        if( (direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK) ){
            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(src_dir),
                            direntry->d_name);
            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(dst_dir), direntry->d_name);
            LOG_DEBUG(1, "stublibs: symlinking %s to %s",
                      utstring_body(src), utstring_body(dst));

            rc = symlink(utstring_body(src),
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                switch (errno) {
                case EEXIST:
                    goto ignore;
                case ENOENT:
                    log_error("symlink ENOENT: %s", strerror(errno));
                    log_error("a component of '%s' does not name an existing file",  utstring_body(dst_dir));
                    fprintf(stderr, "symlink ENOENT: %s\n", strerror(errno));
                    fprintf(stderr, "A component of '%s' does not name an existing file.\n",  utstring_body(dst_dir));
                    break;
                default:
                    log_error("symlink err: %s", strerror(errno));
                    fprintf(stderr, "symlink err: %s", strerror(errno));
                }
                log_error("Exiting");
                fprintf(stderr, "Exiting\n");
                exit(EXIT_FAILURE);
            ignore:
                ;
            }
        }
    }
    closedir(srcd);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_toolchain_buildfiles(char *obazl_pfx,
                                            UT_string *dst_dir)
{
    (void)obazl_pfx;
    TRACE_ENTRY;
    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_printf(dst_file,
                    "%s/selectors/local",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_selector_local_BUILD, */
    /*                toolchain_toolchain_selector_local_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/toolchain/toolchain_selector_local.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

#if defined(XCOMPILE_MACOS)
    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/selectors/macos/x86_64",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_selector_macos_x86_64_BUILD, */
    /*                toolchain_toolchain_selector_macos_x86_64_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/toolchain/toolchain_selector_macos_x86_64.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);


    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/selectors/macos/arm",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_selector_macos_arm_BUILD, */
    /*                toolchain_toolchain_selector_macos_arm_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/toolchain/toolchain_selector_macos_arm.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/selectors/linux/arm",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_selector_linux_arm_BUILD, */
    /*                toolchain_toolchain_selector_linux_arm_BUILD_len, */
    /*                utstring_body(dst_file)); */
#endif

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/profiles",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_profiles_BUILD, */
    /*                toolchain_toolchain_profiles_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/toolchain/toolchain_profiles.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/adapters/local",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");

    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_adapter_local_BUILD, */
    /*                toolchain_toolchain_adapter_local_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/toolchain/toolchain_adapter_local.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

#if defined(XCOMPILE_LINUX)
    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/adapters/linux/x86_64",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_adapter_linux_x86_64_BUILD, */
    /*                toolchain_toolchain_adapter_linux_x86_64_BUILD_len, */
    /*                utstring_body(dst_file)); */

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/adapters/linux/arm",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_adapter_linux_arm_BUILD, */
    /*                toolchain_toolchain_adapter_linux_arm_BUILD_len, */
    /*                utstring_body(dst_file)); */
#endif

#if defined(XCOMPILE_MACOS)
    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/adapters/macos/x86_64",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_adapter_macos_x86_64_BUILD, */
    /*                toolchain_toolchain_adapter_macos_x86_64_BUILD_len, */
    /*                utstring_body(dst_file)); */

    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/adapters/macos/arm",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                toolchain_toolchain_adapter_macos_arm_BUILD, */
    /*                toolchain_toolchain_adapter_macos_arm_BUILD_len, */
    /*                utstring_body(dst_file)); */
#endif
    utstring_free(dst_file);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_bin_build_file(char *bld_file)
{
    TRACE_ENTRY;

    FILE *ostream;
    ostream = fopen(bld_file, "w");
    if (ostream == NULL) {
        log_error("fopen: %s: %s", strerror(errno),
                  bld_file);
        fprintf(stderr, "fopen: %s: %s", strerror(errno),
                bld_file);
        fprintf(stderr, "exiting\n");
        /* perror(utstring_body(dst_file)); */
        exit(EXIT_FAILURE);
    }
    fprintf(ostream, "# generated file - DO NOT EDIT\n");
    fprintf(ostream, "exports_files(glob([\"**\"]))\n\n");
    fclose(ostream);
    LOG_DEBUG(0, " wrote %s\n", bld_file);

    /* **************************************************************** */
    TRACE_EXIT;
}

EXPORT void emit_ocaml_bin_symlinks(UT_string *dst_dir,
                                    char *opam_switch_bin)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "switch_bin: %s", opam_switch_bin);
    LOG_DEBUG(0, "dst_dir: %s", utstring_body(dst_dir));

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    /* UT_string *opam_switch_bin; */
    /* utstring_new(opam_switch_bin); */
    /* utstring_printf(opam_switch_bin, "%s/bin", opam_switch_pfx); */
    LOG_DEBUG(0, "opening src_dir for read: %s", opam_switch_bin);
    DIR *srcd = opendir(opam_switch_bin);
    if (dst == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking toolchain: %s\n",
                opam_switch_bin);
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(srcd)) != NULL) {
        //Condition to check regular file.
        if( (direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK) ){

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            opam_switch_bin,
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(dst_dir), direntry->d_name);

            LOG_DEBUG(1, " symlink: %s -> %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile,  /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                switch (errno) {
                case EEXIST:
                    goto ignore;
                case ENOENT:
                    log_error("symlink ENOENT: %s", strerror(errno));
                    log_error("a component of '%s' does not name an existing file",  utstring_body(dst_dir));
                    fprintf(stderr, "symlink ENOENT: %s\n", strerror(errno));
                    fprintf(stderr, "A component of '%s' does not name an existing file.\n",  utstring_body(dst_dir));
                    break;
                default:
                    log_error("symlink err: %s", strerror(errno));
                    fprintf(stderr, "symlink err: %s", strerror(errno));
                }
                log_error("Exiting");
                fprintf(stderr, "Exiting\n");
                exit(EXIT_FAILURE);
            ignore:
                ;
            }
        }
    }
    closedir(srcd);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_sdkbin_symlinks(UT_string *dst_dir,
                                       char *sdk_bin)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "sdk bin: %s", sdk_bin);
    LOG_DEBUG(0, "dst_dir: %s", utstring_body(dst_dir));

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    LOG_DEBUG(0, "opening src_dir for read: %s", sdk_bin);
    DIR *srcd = opendir(sdk_bin);
    if (dst == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking toolchain: %s\n", sdk_bin);
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(srcd)) != NULL) {
        //Condition to check regular file.
        if( (direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK) ){

            if (strncmp(direntry->d_name, "ocaml", 5) != 0) {
                continue;
            }

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            sdk_bin,
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(dst_dir),
                            direntry->d_name);

            LOG_DEBUG(1, " symlink: %s -> %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                switch (errno) {
                case EEXIST:
                    goto ignore;
                case ENOENT:
                    log_error("symlink ENOENT: %s", strerror(errno));
                    log_error("a component of '%s' does not name an existing file",  utstring_body(dst_dir));
                    fprintf(stderr, "symlink ENOENT: %s\n", strerror(errno));
                    fprintf(stderr, "A component of '%s' does not name an existing file.\n",  utstring_body(dst_dir));
                    break;
                default:
                    log_error("symlink err: %s", strerror(errno));
                    fprintf(stderr, "symlink err: %s", strerror(errno));
                }
                log_error("Exiting");
                fprintf(stderr, "Exiting\n");
                exit(EXIT_FAILURE);
            ignore:
                ;
            }
        }
    }
    closedir(srcd);
    TRACE_EXIT;
}

/* ************************************************ */
/*
  pre-v5: <switch-pfx>/lib/bigarray, redirects to lib/ocaml
  v5+: no bigarray subdir anywhere
*/
EXPORT void emit_ocaml_bigarray_pkg(UT_string *dst_dir,
                                    char *switch_lib)
{
    TRACE_ENTRY;

    UT_string *bigarray_dir;
    utstring_new(bigarray_dir);
    utstring_printf(bigarray_dir,
                    "%s/bigarray", /* < 5.0.0 */
                    switch_lib);
    int rc = access(utstring_body(bigarray_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(bigarray_dir));
        utstring_free(bigarray_dir);
        // v >= 5.0.0 does not include any bigarray archive
        return;
    }

    /* UT_string *templates; */
    /* utstring_new(templates); */
    /* utstring_printf(templates, "%s/%s", */
    /*                 runfiles, "/templates/ocaml"); */

    /* UT_string *src; */
    /* utstring_new(src); */
    UT_string *dst_file;
    utstring_new(dst_file);

    /* utstring_printf(src, "%s/%s", */
    /*                 utstring_body(templates), */
    /*                 "ocaml_bigarray.BUILD"); */
    /* utstring_printf(dst_dir, */
    /*                 "%s/ocamlsdk/lib/bigarray", */
    /*                 coswitch_lib); */
    /* mkdir_r(utstring_body(dst_dir)); */

    /* dst_dir == lib/bigarray */
    utstring_printf(dst_file, "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_bigarray_BUILD, */
    /*           ocamlsdk_bigarray_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/bigarray.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    // if we found <switch>/lib/bigarray,
    // then the files will be in <switch>/lib/ocaml
    // (not <switch>/lib/ocaml/bigarray)
    utstring_renew(bigarray_dir);
    utstring_printf(bigarray_dir,
                    "%s/ocaml",
                    switch_lib);
    _symlink_ocaml_bigarray(bigarray_dir, utstring_body(dst_dir))
        ;

    /* utstring_free(src); */
    utstring_free(dst_file);
    /* utstring_free(templates); */
    utstring_free(bigarray_dir);
    TRACE_EXIT;
}

EXPORT void _symlink_ocaml_bigarray(UT_string *bigarray_dir,
                                    char *tgtdir)
{
    TRACE_ENTRY;
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(bigarray_dir));
    if (d == NULL) {
        perror(utstring_body(bigarray_dir));
        log_error(RED "Unable to opendir for symlinking bigarray" CRESET " %s\n",
                  utstring_body(bigarray_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            /* link files starting with "bigarray" */
            if (strncmp("bigarray", direntry->d_name, 8) != 0)
                continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(bigarray_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);
            LOG_DEBUG(1, "symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));
            errno = 0;
            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    /* perror(utstring_body(src)); */
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/*
  for toplevel <switch>/lib/compiler-libs.
  pre 5.0.0 only?
  all targets aliased to <switch>/lib/ocaml/compiler-libs
*/
EXPORT void emit_compiler_libs_pkg(UT_string *dst_dir,
                                   char *coswitch_lib)
{
    TRACE_ENTRY;
    (void)coswitch_lib;
    LOG_DEBUG(0, "clibs dir: %s", utstring_body(dst_dir));
    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/common",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_buf(compiler_libs_common_BUILD, */
    /*                compiler_libs_common_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/compiler_libs/common.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/bytecomp",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_buf(compiler_libs_bytecomp_BUILD, */
    /*           compiler_libs_bytecomp_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/compiler_libs/bytecomp.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/bytecomp",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_buf(compiler_libs_optcomp_BUILD, */
    /*           compiler_libs_optcomp_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/compiler_libs/optcomp.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/toplevel",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_buf(compiler_libs_toplevel_BUILD, */
    /*           compiler_libs_toplevel_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/compiler_libs/toplevel.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/native-toplevel",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_buf(compiler_libs_native_toplevel_BUILD, */
    /*           compiler_libs_native_toplevel_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/compiler_libs/native_toplevel.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_free(dst_file);

    TRACE_EXIT;
}

/* ************************************************** */
/* for <switch>/lib/ocaml/compiler-libs */
EXPORT void emit_ocaml_compiler_libs_pkg(char *obazl_pfx,
                                         UT_string *dst_dir,
                                         char *switch_lib)
{
    (void)obazl_pfx;
    TRACE_ENTRY;
    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_printf(dst_file,
                    "%s",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_compiler_libs_BUILD, */
    /*                ocamlsdk_compiler_libs_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/compiler_libs.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/common",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_compiler_libs_common_BUILD, */
    /*                ocamlsdk_compiler_libs_common_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/compiler_libs_common.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/bytecomp",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_compiler_libs_bytecomp_BUILD, */
    /*                ocamlsdk_compiler_libs_bytecomp_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/compiler_libs_bytecomp.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/optcomp",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_compiler_libs_optcomp_BUILD, */
    /*                ocamlsdk_compiler_libs_optcomp_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/compiler_libs_optcomp.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/toplevel",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_compiler_libs_toplevel_BUILD, */
    /*                ocamlsdk_compiler_libs_toplevel_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/compiler_libs_toplevel.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    utstring_renew(dst_file);
    utstring_printf(dst_file,
                    "%s/native-toplevel",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_compiler_libs_native_toplevel_BUILD, */
    /*                ocamlsdk_compiler_libs_native_toplevel_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/compiler_libs_native_toplevel.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);


    _symlink_ocaml_compiler_libs(switch_lib,
                                 /* coswitch_lib); */
                                 utstring_body(dst_dir));

    TRACE_EXIT;
}

void _symlink_ocaml_compiler_libs(char *switch_lib,
                                  char *coswitch_lib)
/* char *tgtdir) */
{
    TRACE_ENTRY;
    LOG_DEBUG(1, "switch_lib: %s, coswitch_lib: %s",
              switch_lib, coswitch_lib); //, tgtdir);
    UT_string *opamdir;
    utstring_new(opamdir);
    utstring_printf(opamdir, "%s/ocaml/compiler-libs",
                    switch_lib);

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(opamdir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking compiler-libs: %s\n",
                utstring_body(opamdir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(opamdir), direntry->d_name);

            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            //tgtdir,
                            coswitch_lib,
                            direntry->d_name);

            LOG_DEBUG(2, "symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    perror(utstring_body(src));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_config_pkg(char *obazl_pfx,
                                  UT_string *dst_dir,
                                  char *switch_lib)
{
    (void)obazl_pfx;
    (void)switch_lib;
    TRACE_ENTRY;
    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_printf(dst_file,
                    "%s",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_template(obazl_pfx, */
    /*                ocamlsdk_config_BUILD, */
    /*                ocamlsdk_config_BUILD_len, */
    /*                utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/config.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    TRACE_EXIT;
}

/* ***************************************** */
EXPORT void emit_ocaml_dynlink_pkg(UT_string *dst_dir,
                                   char *switch_lib)
{
    TRACE_ENTRY;
    bool add_toplevel = false;

    UT_string *dynlink_dir;
    utstring_new(dynlink_dir);
    utstring_printf(dynlink_dir,
                    "%s/dynlink",
                    switch_lib);
    int rc = access(utstring_body(dynlink_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(dynlink_dir));
        utstring_new(dynlink_dir);
        utstring_printf(dynlink_dir,
                        "%s/ocaml/dynlink",
                        switch_lib);
        int rc = access(utstring_body(dynlink_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(dynlink_dir));
            utstring_free(dynlink_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET,
                     utstring_body(dynlink_dir));
            add_toplevel = true;
        }
    }

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file, "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_dynlink_BUILD, */
    /*           ocamlsdk_dynlink_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/dynlink.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    if (add_toplevel) {
        // not found: <switch>/lib/dynlink
        // means >= 5.0.0
        // add <coswitch>/lib/dynlink for (bazel) compatibility
        _symlink_ocaml_dynlink(dynlink_dir,
                               utstring_body(dst_dir));
        /* _emit_toplevel(templates, "ocaml_dynlink_alias.BUILD", */
        /*                src, */
        /*                dst_dir, dst_file, */
        /*                coswitch_lib, "dynlink"); */
    } else {
        // if we found <switch>/lib/dynlink (versions < 5.0.0)
        // then we need to populate <coswitch>/lib/ocamlsdk/dynlink
        // (its already there for >= 5.0.0)
        utstring_new(dynlink_dir);
        utstring_printf(dynlink_dir,
                        "%s/ocaml",
                        switch_lib);
        _symlink_ocaml_dynlink(dynlink_dir,
                               utstring_body(dst_dir));
    }

    utstring_free(dst_file);
    utstring_free(dynlink_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_dynlink(UT_string *dynlink_dir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "src: %s, dst: %s",
              utstring_body(dynlink_dir), tgtdir);
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(dynlink_dir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking dynlink: %s\n",
                utstring_body(dynlink_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            /* link files starting with "dynlink" */
            if (strncmp("dynlink", direntry->d_name, 7) != 0)
                continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(dynlink_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);
            LOG_DEBUG(1, "symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));
            errno = 0;
            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ***************************************** */
EXPORT void emit_ocaml_num_pkg(UT_string *dst_dir,
                               char *switch_lib)
{ /* only if opam 'nums' pseudo-pkg was installed */
    TRACE_ENTRY;

    UT_string *num_dir;
    utstring_new(num_dir);
    utstring_printf(num_dir,
                    "%s/num",
                    switch_lib);
    int rc = access(utstring_body(num_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(num_dir));
        return;
    }

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/num/core",
                    utstring_body(dst_dir));
    mkdir_r(utstring_body(dst_file));
    utstring_printf(dst_file, "/BUILD.bazel");
    /* write_buf(ocamlsdk_num_BUILD, */
    /*           ocamlsdk_num_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/num.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    _symlink_ocaml_num(switch_lib, utstring_body(dst_file));

    utstring_free(dst_file);
    TRACE_EXIT;
}

void _symlink_ocaml_num(char *switch_lib, char *tgtdir)
{
    TRACE_ENTRY;

    UT_string *opamdir;
    utstring_new(opamdir);
    utstring_printf(opamdir, "%s/ocaml", switch_lib);

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(opamdir));
    if (d == NULL) {
        perror(utstring_body(opamdir));
        log_error("Unable to opendir for symlinking num: %s\n",
                  utstring_body(opamdir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }
    LOG_DEBUG(0, "reading num dir %s", utstring_body(opamdir));

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if(direntry->d_type==DT_REG){
            if (strncmp("nums.", direntry->d_name, 5) != 0)
                if (strncmp("libnums.", direntry->d_name, 8) != 0)
                    continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(opamdir), direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "symlinking %s to %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    perror(utstring_body(src));
                    fprintf(stderr, "exiting\n");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ***************************************** */
EXPORT void emit_ocaml_profiling_pkg(UT_string *dst_dir,
                                     char *switch_lib)
{
    TRACE_ENTRY;

    UT_string *profiling_dir;
    utstring_new(profiling_dir);
    utstring_printf(profiling_dir,
                    "%s/profiling",
                    switch_lib);
    int rc = access(utstring_body(profiling_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(profiling_dir));
        utstring_new(profiling_dir);
        utstring_printf(profiling_dir,
                        "%s/ocaml/profiling",
                        switch_lib);
        int rc = access(utstring_body(profiling_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(profiling_dir));
            utstring_free(profiling_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET, utstring_body(profiling_dir));
        }
    }

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file, "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_profiling_BUILD, */
    /*           ocamlsdk_profiling_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/profiling.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    _symlink_ocaml_profiling(profiling_dir,
                             utstring_body(dst_dir));

    /* if we found <switch>/lib/profiling (versions < 5.0.0) */
    /* then we need to populate <coswitch>/lib/ocaml/profiling */
    /* (its already there for >= 5.0.0) */

    utstring_free(dst_file);
    utstring_free(profiling_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_profiling(UT_string *profiling_dir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(2, "src: %s, dst: %s", utstring_body(profiling_dir), tgtdir);
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(profiling_dir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking profiling: %s\n",
                utstring_body(profiling_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            /* link files starting with "profiling" */
            if (strncmp("profiling", direntry->d_name, 9) != 0)
                continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(profiling_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            errno = 0;
            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ***************************************** */
EXPORT void emit_ocaml_rtevents_pkg(UT_string *dst_dir,
                                    char *switch_lib)
/* char *coswitch_lib) */
{
    TRACE_ENTRY;
    bool add_toplevel = false;

    UT_string *rtevents_dir;
    utstring_new(rtevents_dir);
    utstring_printf(rtevents_dir,
                    "%s/runtime_events",
                    switch_lib);
    int rc = access(utstring_body(rtevents_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(rtevents_dir));
        utstring_new(rtevents_dir);
        utstring_printf(rtevents_dir,
                        "%s/ocaml/runtime_events",
                        switch_lib);
        int rc = access(utstring_body(rtevents_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(rtevents_dir));
            utstring_free(rtevents_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET, utstring_body(rtevents_dir));
            add_toplevel = true;
        }
    }

    UT_string *dst_file;
    utstring_new(dst_file);

    // 5.0.0+ has <switch>/lib/ocaml/rtevents/META
    // pre-5.0.0: no <switch>/lib/ocaml/rtevents
    // always emit <coswitch>/lib/ocaml/rtevents
    utstring_printf(dst_file,
                    "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_rtevents_BUILD, */
    /*           ocamlsdk_rtevents_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/rtevents.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    if (add_toplevel) {
        // not found: <switch>/lib/rtevents
        // means >= 5.0.0
        // add <coswitch>/lib/rtevents for (bazel) compatibility
        _symlink_ocaml_rtevents(rtevents_dir,
                                utstring_body(dst_dir));
        /* _emit_toplevel(templates, "ocaml_rtevents_alias.BUILD", */
        /*                src, */
        /*                dst_dir, dst_file, */
        /*                coswitch_lib, "runtime_events"); */
    } else {
        // if we found <switch>/lib/rtevents (versions < 5.0.0)
        // then we need to populate <coswitch>/lib/ocaml/rtevents
        // (its already there for >= 5.0.0)
        utstring_new(rtevents_dir);
        utstring_printf(rtevents_dir,
                        "%s/ocaml",
                        switch_lib);
        _symlink_ocaml_rtevents(rtevents_dir,
                                utstring_body(dst_dir));
    }

    utstring_free(dst_file);
    utstring_free(rtevents_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_rtevents(UT_string *rtevents_dir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(2, "src: %s, dst: %s",
              utstring_body(rtevents_dir), tgtdir);
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(rtevents_dir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking rtevents: %s\n",
                utstring_body(rtevents_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            /* link files starting with "rtevents" */
            if (strncmp("runtime_events", direntry->d_name, 7) != 0)
                continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(rtevents_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            errno = 0;
            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ************************************* */
EXPORT void emit_ocaml_str_pkg(UT_string *dst_dir,
                               char *switch_lib)
{
    TRACE_ENTRY;

    // add_toplevel true means ocaml version >= 5.0.0
    // which means switch lacks lib/str
    // but we add it to coswitch so @str//lib/str will
    // work with >= 5.0.0
    bool add_toplevel = false;

    UT_string *str_dir;
    utstring_new(str_dir);
    utstring_printf(str_dir,
                    "%s/str",   /* < 5.0.0 */
                    switch_lib);
    int rc = access(utstring_body(str_dir), F_OK);
    if (rc == 0) {
        /* found lib/str, < 5.0.0 */
        LOG_WARN(0, YEL "FOUND: %s" CRESET,
                 utstring_body(str_dir));

    } else {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(str_dir));
        utstring_new(str_dir);
        utstring_printf(str_dir,
                        "%s/ocaml/str", /* >= 5.0.0 */
                        switch_lib);
        int rc = access(utstring_body(str_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(str_dir));
            utstring_free(str_dir);
            return;
        } else {
            // found lib/ocaml/str
            LOG_WARN(0, YEL "FOUND: %s" CRESET,
                     utstring_body(str_dir));
            add_toplevel = true;
        }
    }

    UT_string *dst_file;
    utstring_new(dst_file);

    if (add_toplevel) {
        /* we found lib/ocaml/str, so we need to emit the */
        /* toplevel w/alias, lib/str */
        /* but we only symlink to lib/ocamlsdk/lib/str */
        /* LOG_DEBUG(0, "EMITTING STR TOPLEVEL"); */

        /* dst_dir == "lib/str" */
        utstring_printf(dst_file, "%s/BUILD.bazel",
                        utstring_body(dst_dir));
        mkdir_r(utstring_body(dst_dir));
        utstring_renew(dst_file);
        utstring_printf(dst_file,
                        "%s/BUILD.bazel",
                        utstring_body(dst_dir));
        /* write_buf(ocamlsdk_str_BUILD, */
        /*           ocamlsdk_str_BUILD_len, */
        /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/str.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

        // but symlink to lib/ocaml/str
        _symlink_ocaml_str(str_dir, utstring_body(dst_dir));

    } else {
        // if we found <switch>/lib/str (versions < 5.0.0)
        // then we need to link
        // from <coswitch>/lib/ocaml
        // to <coswitch>/lib/ocaml/lib/str
        /* dst_dir == "lib/str" */
        mkdir_r(utstring_body(dst_dir));
        utstring_printf(dst_file, "%s/BUILD.bazel",
                        utstring_body(dst_dir));
        /* write_buf(ocamlsdk_str_BUILD, */
        /*           ocamlsdk_str_BUILD_len, */
        /*           utstring_body(dst_file)); */
        f = BAZEL_CURRENT_REPOSITORY
            "/lib/templates/ocamlsdk/str.BUILD";
        rf = rf_rlocation(f);
        copy_buildfile(rf, dst_file);

        utstring_new(str_dir);
        utstring_printf(str_dir,
                        "%s/ocaml",
                        switch_lib);
        _symlink_ocaml_str(str_dir,
                           utstring_body(dst_dir));

    }
    utstring_free(dst_file);
    utstring_free(str_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_str(UT_string *str_dir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(2, "src: %s,\n\tdst %s",
                  utstring_body(str_dir),
                  tgtdir);

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(str_dir));
    if (d == NULL) {
        log_error("Unable to opendir for symlinking str: %s\n",
                  utstring_body(str_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    } else {
        LOG_DEBUG(0, "fopened %s as symlink src",
                  utstring_body(str_dir));
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            /* link files starting with "str." */
            if (strncmp("str.", direntry->d_name, 4) != 0)
                continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(str_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ***************************************** */
/**
   pre-5.0.0: <switch>/threads and <switch>/lib/ocaml/threads
   5.0.0+:    <switch>/lib/ocaml/threads only
*/
EXPORT void emit_ocaml_threads_pkg(UT_string *dst_dir,
                                   char *switch_lib)
{
    TRACE_ENTRY;
    bool add_toplevel = false;

    UT_string *threads_dir;
    utstring_new(threads_dir);
    utstring_printf(threads_dir,
                    "%s/threads",
                    switch_lib);
    int rc = access(utstring_body(threads_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(threads_dir));
        utstring_new(threads_dir);
        utstring_printf(threads_dir,
                        "%s/ocaml/threads",
                        switch_lib);
        int rc = access(utstring_body(threads_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(threads_dir));
            utstring_free(threads_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET,
                     utstring_body(threads_dir));
            add_toplevel = true;
        }
    }

    // 5.0.0+ has <switch>/lib/ocaml/threads
    // pre-5.0.0: no <switch>/lib/ocaml/threads
    // always emit <coswitch>/lib/ocaml/threads
    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_printf(dst_file, "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_threads_BUILD, */
    /*           ocamlsdk_threads_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/threads.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    if (add_toplevel) {
        // not found: <switch>/lib/threads
        // means >= 5.0.0
        // add <coswitch>/lib/threads for (bazel) compatibility
        /* _emit_toplevel(templates, */
        /*                "ocaml_threads_alias.BUILD", */
        /*                src, */
        /*                dst_dir, dst_file, */
        /*                coswitch_lib, */
        /*                "threads"); */
    }
    // all versions have <switch>/lib/ocaml/threads
    // so we always symlink to <coswitch>/lib/ocaml/threads
    utstring_new(threads_dir);
    utstring_printf(threads_dir,
                    "%s/ocaml",
                    switch_lib);

    _symlink_ocaml_threads(threads_dir, utstring_body(dst_dir));

    utstring_free(dst_file);
    utstring_free(threads_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_threads(UT_string *threads_dir, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(2, "  src: %s", utstring_body(threads_dir));
    LOG_DEBUG(2, "  dst: %s", tgtdir);
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    static char *srcfile;

    utstring_printf(src, "%s/libthreads.a",
                    utstring_body(threads_dir));
    srcfile = realpath(utstring_body(src), NULL);

    //FIXME: verify access
    utstring_printf(dst, "%s/libthreads.a",
                    tgtdir);

    LOG_DEBUG(1, " symlink: %s -> %s\n",
              srcfile, /* utstring_body(src), */
              utstring_body(dst));

    rc = symlink(srcfile, /* utstring_body(src), */
                 utstring_body(dst));
    symlink_ct++;
    if (rc != 0) {
        if (errno != EEXIST) {
            log_error("ERROR: %s", strerror(errno));
            log_error("src: %s, dst: %s",
                      utstring_body(src),
                      utstring_body(dst));
            log_error("exiting");
            exit(EXIT_FAILURE);
        }
    }

    utstring_renew(src);
    utstring_printf(src, "%s/libthreadsnat.a",
                    utstring_body(threads_dir));
    free(srcfile);
    srcfile = realpath(utstring_body(src), NULL);

    utstring_renew(dst);
    utstring_printf(dst, "%s/libthreadsnat.a",
                    tgtdir);

    LOG_DEBUG(1, " symlink: %s -> %s\n",
              srcfile, /* utstring_body(src), */
              utstring_body(dst));

    rc = symlink(srcfile, /* utstring_body(src), */
                 utstring_body(dst));
    symlink_ct++;
    if (rc != 0) {
        if (errno != EEXIST) {
            log_error("ERROR: %s", strerror(errno));
            log_error("src: %s, dst: %s",
                      utstring_body(src),
                      utstring_body(dst));
            log_error("exiting");
            exit(EXIT_FAILURE);
        }
    }
    free(srcfile);

    utstring_printf(threads_dir, "/%s", "threads");
    DIR *d = opendir(utstring_body(threads_dir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking threads: %s\n",
                utstring_body(threads_dir));
        log_error("Unable to opendir for symlinking threads: %s\n", utstring_body(threads_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(threads_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "symlinking %s to %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ***************************************** */
//FIXMEFIXME
EXPORT void emit_ocaml_ocamldoc_pkg(UT_string *dst_dir,
                                    char *switch_lib)
{
    TRACE_ENTRY;

    UT_string *ocamldoc_dir;
    utstring_new(ocamldoc_dir);
    utstring_printf(ocamldoc_dir,
                    "%s/ocamldoc",
                    switch_lib);
    int rc = access(utstring_body(ocamldoc_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(ocamldoc_dir));
        utstring_new(ocamldoc_dir);
        utstring_printf(ocamldoc_dir,
                        "%s/ocaml/ocamldoc",
                        switch_lib);
        int rc = access(utstring_body(ocamldoc_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(ocamldoc_dir));
            utstring_free(ocamldoc_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET,
                     utstring_body(ocamldoc_dir));
        }
    }

    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_printf(dst_file, "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_ocamldoc_BUILD, */
    /*           ocamlsdk_ocamldoc_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/ocamldoc.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    _symlink_ocaml_ocamldoc(ocamldoc_dir, utstring_body(dst_dir));

    utstring_free(dst_file);
    utstring_free(ocamldoc_dir);
    TRACE_EXIT;
}

void _symlink_ocaml_ocamldoc(UT_string *ocamldoc_dir,
                             char *tgtdir)
{
    TRACE_ENTRY;
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(ocamldoc_dir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking ocamldoc: %s\n",
                utstring_body(ocamldoc_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(ocamldoc_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "ocamldoc symlinking %s to %s",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst));

            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
    TRACE_EXIT;
}

EXPORT void emit_ocaml_unix_pkg(UT_string *dst_dir,
                                char *switch_lib)
{
    TRACE_ENTRY;
    bool add_toplevel = false;

    UT_string *unix_dir;
    utstring_new(unix_dir);
    utstring_printf(unix_dir,
                    "%s/unix",
                    switch_lib);

    int rc = access(utstring_body(unix_dir), F_OK);
    if (rc != 0) {
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                 utstring_body(unix_dir));
        utstring_new(unix_dir);
        utstring_printf(unix_dir,
                        "%s/ocaml/unix",
                        switch_lib);
        int rc = access(utstring_body(unix_dir), F_OK);
        if (rc != 0) {
            LOG_WARN(0, YEL "NOT FOUND: %s" CRESET,
                     utstring_body(unix_dir));
            utstring_free(unix_dir);
            return;
        } else {
            LOG_WARN(0, YEL "FOUND: %s" CRESET, utstring_body(unix_dir));
            /* did not find <switch>/unix (< 5.0) */
            /* found <switch>/ocaml/unix meaning >= 5.0 */
            add_toplevel = true;
        }
    }
    UT_string *dst_file;
    utstring_new(dst_file);

    // 5.0.0+ has <switch>/lib/ocaml/unix
    // pre-5.0.0: no <switch>/lib/ocaml/unix
    // always emit <coswitch>/lib/ocaml/lib/unix,
    // even for < 5.0.0, for obazl compat
    utstring_printf(dst_file,
                    "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_unix_BUILD, */
    /*           ocamlsdk_unix_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/unix.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    if (add_toplevel) {
        // found <switch>/lib/ocaml/unix, not found <switch>/lib/unix, means >= 5.0.0
        // link the former,
        // add <coswitch>/lib/unix alias for (bazel) compat
        // link files in lib/ocaml/unix
        _symlink_ocaml_unix(unix_dir,
                            utstring_body(dst_dir));

        // link lib/ocaml/libunixbyt.a, libunixnat.a
        _symlink_libunix(switch_lib, dst_dir, dst_file, symlink_ct);
    } else {
        // if we found <switch>/lib/unix (versions < 5.0.0)
        // then we need to link to <coswitch>/lib/ocaml/unix
        // (its already there for >= 5.0.0)
        utstring_new(unix_dir);
        utstring_printf(unix_dir,
                        "%s/ocaml",
                        switch_lib);
        _symlink_ocaml_unix(unix_dir, utstring_body(dst_dir));
    }

    utstring_free(dst_file);
    utstring_free(unix_dir);
    TRACE_EXIT;
}

void _symlink_libunix(char *switch_lib,
                      UT_string *dst_dir, UT_string *dst_file,
                      int symlink_ct)
{
    TRACE_ENTRY;
    (void)symlink_ct;
    /* first try v >= 5.1 */
    static char *srcfile;

    UT_string *src;
    utstring_new(src);
    utstring_printf(src, "%s/ocaml/libunixnat.a",
                    switch_lib);
    srcfile = realpath(utstring_body(src), NULL);

    int rc = access(srcfile, F_OK); //utstring_body(src), F_OK);
    if (rc == 0) {
        LOG_WARN(0, YEL "FOUND: %s" CRESET, srcfile);
        utstring_renew(dst_file);
        utstring_printf(dst_file, "%s/libunixnat.a",
                        utstring_body(dst_dir));
        LOG_DEBUG(1, "SYMLINKING %s to %s\n",
                  srcfile, /* utstring_body(src), */
                  utstring_body(dst_file));
        rc = symlink(srcfile, /* utstring_body(src), */
                     utstring_body(dst_file));
        if (rc != 0) {
            if (errno != EEXIST) {
                log_error("ERROR: %s", strerror(errno));
                log_error("src: %s, dst: %s",
                          utstring_body(src),
                          utstring_body(dst_file));
                log_error("exiting");
                exit(EXIT_FAILURE);
            } else {
                /* ??? */
            }
        }
        symlink_ct++;
        /* now libunixbyt.a */
        utstring_renew(src);
        utstring_printf(src, "%s/ocaml/libunixbyt.a",
                        switch_lib);
        free(srcfile);
        srcfile = realpath(utstring_body(src), NULL);
        int rc = access(srcfile, F_OK);
        if (rc == 0) {
#if defined(PROFILE_fastbuild)
            LOG_WARN(0, YEL "FOUND: %s" CRESET, utstring_body(src));
#endif
            utstring_renew(dst_file);
            utstring_printf(dst_file, "%s/libunixbyt.a",
                            utstring_body(dst_dir));
            LOG_DEBUG(1, "SYMLINKING %s to %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst_file));
            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst_file));
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst_file));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                } else {
                    /* ??? */
                }
            }
            symlink_ct++;
            free(srcfile);
        } else {
            /* libunixbyt.a not found after libunixnat.a found */
#if defined(PROFILE_fastbuild)
            LOG_WARN(0, YEL "FOUND: %s" CRESET, utstring_body(src));
#endif
        }
    } else {
        free(srcfile);
        /* libunixnat.a not found, try libunix.a (pre 5.1.0) */
#if defined(PROFILE_fastbuild)
        LOG_WARN(0, YEL "NOT FOUND: %s" CRESET, utstring_body(src));
#endif
        utstring_renew(src);
        utstring_printf(src, "%s/ocaml/libunix.a",
                        switch_lib);
        srcfile = realpath(utstring_body(src), NULL);
        int rc = access(srcfile, F_OK);
        if (rc == 0) {
            utstring_renew(dst_file);
            utstring_printf(dst_file, "%s/libunix.a",
                            utstring_body(dst_dir));
            LOG_DEBUG(1, "SYMLINKING %s to %s\n",
                      srcfile, /* utstring_body(src), */
                      utstring_body(dst_file));
            rc = symlink(srcfile, /* utstring_body(src), */
                         utstring_body(dst_file));
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst_file));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                } else {
                    /* ??? */
                }
            }
            symlink_ct++;
        } else {
            /* libunix.a NOT found */
        }
        free(srcfile);
        /* libunixnat.a NOT found */
    }
}

void _symlink_ocaml_unix(UT_string *unix_dir, char *tgtdir)
{
    TRACE_ENTRY_MSG("src: %s", unix_dir);
    LOG_DEBUG(0, "unix_dir: %s", utstring_body(unix_dir));
    LOG_DEBUG(0, "tgtdir: %s", tgtdir);
    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(unix_dir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking unix: %s\n",
                utstring_body(unix_dir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            /* link files starting with "unix." etc. */
            if (strncmp("unix.", direntry->d_name, 5) != 0)
                if (strncmp("unixLabels.", direntry->d_name, 11) != 0)
                    if (strncmp("libunix", direntry->d_name, 7) != 0)
                        continue;

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(unix_dir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            tgtdir, direntry->d_name);

            LOG_DEBUG(1, "symlinking %s to %s",
                      srcfile, utstring_body(dst));

            rc = symlink(srcfile, utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/* ***************************************** */
EXPORT void emit_ocaml_c_ffi_pkg(UT_string *dst_dir,
                                 char *switch_lib)
{
    TRACE_ENTRY;
    (void)switch_lib;

    UT_string *dst_file;
    utstring_new(dst_file);
    utstring_printf(dst_file,
                    "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    /* write_buf(ocamlsdk_c_ffi_BUILD, */
    /*           ocamlsdk_c_ffi_BUILD_len, */
    /*           utstring_body(dst_file)); */
    f = BAZEL_CURRENT_REPOSITORY
        "/lib/templates/ocamlsdk/c_ffi.BUILD";
    rf = rf_rlocation(f);
    copy_buildfile(rf, dst_file);

    _symlink_ocaml_c_hdrs(switch_lib, utstring_body(dst_dir));

    utstring_free(dst_file);
    TRACE_EXIT;
}

void _symlink_ocaml_c_hdrs(char *switch_lib, char *tgtdir)
{
    TRACE_ENTRY;
    /* LOG_DEBUG(0, "switch lib: %s", switch_lib); */
    /* LOG_DEBUG(0, "tgtdir: %s", tgtdir); */
    UT_string *opamdir;
    utstring_new(opamdir);
    utstring_printf(opamdir, "%s/ocaml/caml", switch_lib);

    UT_string *obazldir;
    utstring_new(obazldir);
    utstring_printf(obazldir, "%s/caml", tgtdir);
    mkdir_r(utstring_body(obazldir));

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(opamdir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking c ffi: %s\n",
                utstring_body(opamdir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(opamdir),
                            direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(obazldir),
                            direntry->d_name);

            LOG_DEBUG(1, " symlink: %s -> %s\n",
                      srcfile, utstring_body(dst));
            errno = 0;
            rc = symlink(srcfile, utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    log_error("ERROR: %s", strerror(errno));
                    log_error("src: %s, dst: %s",
                              utstring_body(src),
                              utstring_body(dst));
                    log_error("exiting");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
}

void _symlink_ocaml_runtime_libs(char *switch_lib, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "\tswitch_lib: %s\n", switch_lib);
    LOG_DEBUG(0, "\ttgtdir    : %s\n", tgtdir);

    UT_string *opamdir;
    utstring_new(opamdir);
    utstring_printf(opamdir, "%s/ocaml", switch_lib);

    UT_string *obazldir;
    utstring_new(obazldir);
    utstring_printf(obazldir, "%s", tgtdir);
    mkdir_r(utstring_body(obazldir));

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(opamdir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking c_libs: %s\n",
                utstring_body(opamdir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {

            if (strncmp("lib", direntry->d_name, 3) != 0) {
                if (strncmp("stdlib.a",
                            direntry->d_name, 8) != 0) {
                    continue;
                }
            }
            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(opamdir), direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(obazldir), /* tgtdir, */
                            direntry->d_name);

            LOG_DEBUG(1, "c_libs: symlinking %s to %s",
                      srcfile, utstring_body(dst));
            errno = 0;
            rc = symlink(srcfile, utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    fprintf(stdout, "c_libs symlink errno: %d: %s\n",
                            errno, strerror(errno));
                    fprintf(stdout, "c_libs src: %s, dst: %s\n",
                            utstring_body(src),
                            utstring_body(dst));
                    fprintf(stderr, "exiting\n");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
}

void _symlink_ocaml_runtime_compiler_libs(char *switch_lib, char *tgtdir)
{
    TRACE_ENTRY;
    LOG_DEBUG(0, "\tswitch_lib: %s\n", switch_lib);
    LOG_DEBUG(0, "\ttgtdir    : %s\n", tgtdir);

    UT_string *opamdir;
    utstring_new(opamdir);
    utstring_printf(opamdir, "%s/ocaml/compiler-libs", switch_lib);

    UT_string *obazldir;
    utstring_new(obazldir);
    utstring_printf(obazldir, "%s", tgtdir);
    mkdir_r(utstring_body(obazldir));

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    DIR *d = opendir(utstring_body(opamdir));
    if (d == NULL) {
        fprintf(stderr, "Unable to opendir for symlinking c_libs: %s\n",
                utstring_body(opamdir));
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */
        return;
    }

    struct dirent *direntry;
    static char *srcfile;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            if (strncmp("ocaml", direntry->d_name, 5) != 0) {
                continue;
            }
            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(opamdir), direntry->d_name);
            srcfile = realpath(utstring_body(src), NULL);

            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(obazldir), /* tgtdir, */
                            direntry->d_name);
            LOG_DEBUG(1, "c_libs: symlinking %s to %s",
                      srcfile, utstring_body(dst));
            errno = 0;
            rc = symlink(srcfile, utstring_body(dst));
            symlink_ct++;
            if (rc != 0) {
                if (errno != EEXIST) {
                    fprintf(stdout, "c_libs symlink errno: %d: %s\n",
                            errno, strerror(errno));
                    fprintf(stdout, "c_libs src: %s, dst: %s\n",
                            utstring_body(src),
                            utstring_body(dst));
                    fprintf(stderr, "exiting\n");
                    exit(EXIT_FAILURE);
                }
            }
            free(srcfile);
        }
    }
    closedir(d);
}

EXPORT void emit_ocaml_version(UT_string *dst_dir,
                               char *coswitch_lib,
                               char *version)
{
    TRACE_ENTRY;
    (void)coswitch_lib;
    UT_string *dst_file;
    utstring_new(dst_file);

    utstring_printf(dst_file,
                    "%s/BUILD.bazel",
                    utstring_body(dst_dir));
    LOG_DEBUG(0, "version file: %s", utstring_body(dst_dir));
    errno = 0;
    FILE *ostream;
    ostream = fopen(utstring_body(dst_file), "w");
    if (ostream == NULL) {
        log_error("fopen fail on %s: %s",
                  utstring_body(dst_file),
                  strerror(errno));
        exit(EXIT_FAILURE);
    }

    fprintf(ostream, "## generated file - DO NOT EDIT\n");

    fprintf(ostream,
            "load(\"@bazel_skylib//rules:common_settings.bzl\", \"string_setting\")\n\n");

    fprintf(ostream,
            "package(default_visibility=[\"//visibility:public\"])\n\n");

    fprintf(ostream,
            "string_setting(name = \"version\",\n"
            "               build_setting_default = \"%s\")\n",
            version);

    fclose(ostream);

    LOG_DEBUG(2, " wrote: %s\n", utstring_body(dst_file));
    utstring_free(dst_file);
    TRACE_EXIT;
}
