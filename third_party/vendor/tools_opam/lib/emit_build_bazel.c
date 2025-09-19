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

#include "liblogc.h"
/* #include "semver.h" */
#include "utarray.h"
#if EXPORT_INTERFACE
#include "utstring.h"
#endif

#include "findlibc.h"

#include "emit_build_bazel.h"

extern int level;
extern int spfactor;
extern char *sp;

extern int log_writes;
extern int log_symlinks;

#define DEBUG_LEVEL coswitch_debug
int  DEBUG_LEVEL;
#define TRACE_FLAG coswitch_trace
bool TRACE_FLAG;
extern int indent;
extern int delta;

char *ocaml_ws;

extern bool verbose;
extern int debug;
extern bool trace;

UT_string *bazel_repo_name;
UT_string *bazel_pkg_label;
UT_string *build_bazel_file;

int symlink_ct;

extern char *default_version;
extern int   default_compat;
extern char *bazel_compat;

bool distrib_pkg;

/* ********************************** */
LOCAL void emit_bazel_hdr(FILE* ostream)
{
    fprintf(ostream,
            "load(\"@rules_ocaml//build:rules.bzl\", \"ocaml_import\")\n");

    //FIXME: only if --enable-jsoo passed
    /* fprintf(ostream, */
    /*         "load(\"@rules_jsoo//build:rules.bzl\", \"jsoo_library\", \"jsoo_import\")\n\n"); */

}

/* ********************************** */
LOCAL void emit_bazel_cc_imports(FILE* ostream,
                           int level, /* indentation control */
                           char *_pkg_prefix,
                           char *_pkg_name,
                           char *_filedeps_path, /* _lib */
                           obzl_meta_entries *_entries,
                           obzl_meta_package *_pkg)
{
    (void)level;
    (void)_entries;
    (void)_filedeps_path;
    (void)_pkg;
    (void)_pkg_name;
    (void)_pkg_prefix;
    char *dname = dirname(utstring_body(build_bazel_file));

    errno = 0;
    DIR *d = opendir(dname);
    if (d == NULL) {
        fprintf(stderr,
                "%s:%d ERROR: bad opendir %s: %s\n",
                __FILE__, __LINE__,
                dname, strerror(errno));
        return;
    }

    /* RASH ASSUMPTION: only one stublib per directory */
    /* wrong: base has two */
    struct dirent *direntry;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            if (fnmatch("lib*stubs.a", direntry->d_name, 0) == 0) {
                fprintf(ostream, "cc_import(\n");
                fprintf(ostream, "    name           = \"_%s\",\n",
                        direntry->d_name);
                fprintf(ostream, "    static_library = \"%s\",\n",
                        direntry->d_name);
                fprintf(ostream, ")\n");
            } else {
                if (fnmatch("*stubs.so", direntry->d_name, 0) == 0)
                    {
                        printf("FOUND SO LIB: %s\n", direntry->d_name);
                    }
                /* printf("skipping %s\n", direntry->d_name); */
            }
        }
    }
    closedir(d);
}

UT_array *cc_stubs;

LOCAL void emit_bazel_stublibs_attr(FILE* ostream,
                                    char *coswitch_pkg_root,
                                    char *coswitch_lib,
                                    int level, /* indentation lvl */
                                    char *_pkg_root,
                                    char *_pkg_prefix,
                                    char *obazl_pfx, /* for bazel name, e.g. 'opam.' */
                                    char *_pkg_name,
                                    UT_string *_pkg_parent,
                                    char *_filedeps_path, /* _lib */
                                    obzl_meta_entries *_entries,
                                    obzl_meta_package *_pkg)
{
    TRACE_ENTRY;
    (void)obazl_pfx;
    (void)coswitch_lib;
    (void)coswitch_pkg_root;
    (void)_entries;
    (void)_filedeps_path;
    (void)_pkg;
    /* here we read the symlinks in the coswitch not the opam switch */
    LOG_DEBUG(0, "coswitch pkg root: '%s'", coswitch_pkg_root);
    LOG_DEBUG(0, " pkg root: '%s'", _pkg_root);
    LOG_DEBUG(0, " pkg prefix: '%s'", _pkg_prefix);
    LOG_DEBUG(0, " pkg name: '%s'", _pkg_name);
    LOG_DEBUG(0, " pkg parent: '%s'", utstring_body(_pkg_parent));

    static UT_string *dname;
    utstring_new(dname);
    if (_pkg_prefix == 0) {
        utstring_printf(dname, "lib");
    } else {
        utstring_printf(dname, "%s/%s/lib",
                        utstring_body(_pkg_parent),
                        _pkg_name);
    }

                    /* "%s/lib", */
                    /* coswitch_pkg_root); */
    /* if (_pkg_parent != NULL) { */
    /*     if (utstring_len(_pkg_parent) > 0) { */
    /*         utstring_printf(dname, "/%s", utstring_body(_pkg_parent)); */
    /*     } */
    /* } */
    /* utstring_printf(dname, "/%s", _pkg_name); */

    LOG_DEBUG(0, "emit_bazel_stublibs_attr: %s",
              utstring_body(dname));

    errno = 0;
    DIR *d = opendir(utstring_body(dname));
    if (d == NULL) {
        fprintf(stdout,
                "%s:%d ERROR: bad opendir: %s\n\t%s\n",
                __FILE__, __LINE__,
                strerror(errno),
                utstring_body(dname));
        fprintf(ostream,
                "%s:%d ERROR: bad opendir: %s\n\t%s\n",
                __FILE__, __LINE__,
                strerror(errno),
                utstring_body(dname));
        fprintf(ostream, "## pkg root: %s\n", _pkg_root);
        fprintf(ostream, "## pkg parent: %s\n", utstring_body(_pkg_parent));
        fprintf(ostream, "## _pkg_prefix: %s\n", _pkg_prefix);
        fprintf(ostream, "## _pkg_name: %s\n", _pkg_name);
        fflush(NULL);
        return;
    }

    utarray_new(cc_stubs, &ut_str_icd);
    char strbuf[128];
    char *sbuf = (char*)&strbuf;
    struct dirent *direntry;
    int name_len;

    errno = 0;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            if (fnmatch("lib*stubs.a", direntry->d_name, 0) == 0) {
                name_len = strlen(direntry->d_name);
                memcpy(strbuf, direntry->d_name, 128);
                strbuf[name_len] = '\0';
                utarray_push_back(cc_stubs, &sbuf);

            } else {
                if (fnmatch("*stubs.so", direntry->d_name, 0) == 0)
                    {
                        printf("FOUND SO STUBLIB: %s\n", direntry->d_name);
                    }
            }
        }
        errno = 0;
    }
    if (errno != 0) {
        log_error("Error in readdir");
    }

    char **p;
    p = NULL;
    fprintf(ostream, "%*scc_deps   = [\n", level*spfactor, sp);
    while ( (p=(char**)utarray_next(cc_stubs, p)) ) {
        fprintf(ostream, "        \":_%s\",\n", *p);
    }
    fprintf(ostream, "%*s],\n", level*spfactor, sp);

    utarray_free(cc_stubs);

    closedir(d);
}

//FIXME: only if --enable-jsoo passed
#if defined(JSOO_ENABLED)
LOCAL void emit_bazel_jsoo_runtime_attr(FILE* ostream,
                                  char *coswitch_lib,
                                  int level, /* indentation control */
                                  char *_pkg_root,
                                  char *_pkg_prefix,
                                  char *_pkg_name,
                                  UT_string *_pkg_parent,
                                  char *_filedeps_path, /* _lib */
                                  obzl_meta_entries *_entries,
                                  obzl_meta_package *_pkg)
{
    (void)_entries;
    (void)_filedeps_path;
    (void)_pkg;
    /* here we read the symlinks in the coswitch not the opam switch */
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, "jsoo pkg root: %s", _pkg_root);
    LOG_DEBUG(0, "jsoo pkg prefix: %s", _pkg_prefix);
    LOG_DEBUG(0, "jsoo pkg name: %s", _pkg_name);
    LOG_DEBUG(0, "jsoo pkg parent: %s", utstring_body(_pkg_parent));
#endif

    static UT_string *dname;
    utstring_new(dname);
    utstring_printf(dname, "%s/%s/lib",
                    coswitch_lib, /* e.g. <switch>/lib */
                    /* FIXME: what about multilevels, e.g.
                     @foo//lib/bar/baz/buz ? */
                    _pkg_root);
    if (_pkg_parent != NULL)
        utstring_printf(dname, "/%s", utstring_body(_pkg_parent));
    utstring_printf(dname, "/%s", _pkg_name);

    LOG_DEBUG(0, "emit_bazel_jsoo_runtime_attr: %s", utstring_body(dname));

    errno = 0;
    DIR *d = opendir(utstring_body(dname));
    if (d == NULL) {
        fprintf(stderr,
                "%s:%d ERROR: bad opendir: %s\n",
                __FILE__, __LINE__,
                strerror(errno));
                /* "ERROR: bad opendir: %s\n", strerror(errno)); */
        fprintf(ostream, "## ERROR: bad opendir: %s\n", utstring_body(dname));
        fprintf(ostream, "## Pkg root: %s\n", _pkg_root);
        fprintf(ostream, "## Pkg parent: %s\n", utstring_body(_pkg_parent));
        fprintf(ostream, "## _pkg_prefix: %s\n", _pkg_prefix);
        fprintf(ostream, "## _pkg_name: %s\n", _pkg_name);
        return;
    }

    /* bool wrote_loader = false; */

    /* TODO: read jsoo_runtime property of META */

    struct dirent *direntry;
    while ((direntry = readdir(d)) != NULL) {
        if ((direntry->d_type==DT_REG)
            || (direntry->d_type==DT_LNK)) {
            if (fnmatch("runtime.js", direntry->d_name, 0) == 0) {
                fprintf(ostream, "%*sjsoo_runtime = \"%s\",\n",
                        level*spfactor, sp, direntry->d_name);

                /* fprintf(ostream, "cc_import(\n"); */
                /* fprintf(ostream, "    name    = \"%s_stubs\",\n", */
                /*         _pkg_name); */
                /* fprintf(ostream, "    archive = \"%s\",\n", */
                /*         direntry->d_name); */
                /* fprintf(ostream, ")\n"); */
            /* } */
                /* printf("skipping %s\n", direntry->d_name); */
            }
        }
    }
    closedir(d);
}
#endif

LOCAL void emit_bazel_archive_attr(FILE* ostream,
                             int level, /* indentation control */
                              char *_pkg_prefix,
                             char *_pkg_name,
                             /* for constructing import label: */
                             char *_filedeps_path,
                             obzl_meta_entries *_entries,
                             char *property, /* always 'archive' */
                             obzl_meta_package *_pkg)
{
    (void)level;
    (void)_pkg;
    (void)_pkg_name;
    (void)_filedeps_path;

    LOG_DEBUG(0, "EMIT_BAZEL_ARCHIVE_ATTR _pkg_name: '%s'; prop: '%s'; filedeps path: '%s'",
              _pkg_name, property, _filedeps_path);
    LOG_DEBUG(0, "  pkg_prefix: %s", _pkg_prefix);

    LOG_DEBUG(0, "_filedeps_path: '%s'", _filedeps_path);

    struct obzl_meta_property *deps_prop = obzl_meta_entries_property(_entries, property);
    if ( deps_prop == NULL ) {
        LOG_WARN(0, "Prop '%s' not found: %s.", property); //, pkg_name);
        return;
    }

    obzl_meta_settings *settings = obzl_meta_property_settings(deps_prop);

    int settings_ct = obzl_meta_settings_count(settings);
    LOG_INFO(0, "settings count: %d", settings_ct);
    if (settings_ct == 0) {
        LOG_INFO(0, "No settings for %s", obzl_meta_property_name(deps_prop));
        return;
    }
    UT_string *cmtag;  /* cma or cmxa */
    utstring_new(cmtag);

    obzl_meta_setting *setting = NULL;

    obzl_meta_values *vals;
    obzl_meta_value *archive_name = NULL;

    /* lhs */
    fprintf(ostream, "    archive  =  select({\n");

    /* iter over archive(byte), archive(native) */
    for (int i = 0; i < settings_ct; i++) {
        setting = obzl_meta_settings_nth(settings, i);
        LOG_DEBUG(0, "setting[%d]", i+1);
        /* dump_setting(0, setting); */

        obzl_meta_flags *flags = obzl_meta_setting_flags(setting);
        /* skip any setting with deprecated flag, e.g. 'vm' */
        if (obzl_meta_flags_deprecated(flags)) {
            continue;
        }

        vals = resolve_setting_values(setting, flags, settings);

        bool has_conditions = false;
        if (flags == NULL)
            utstring_printf(cmtag, "//conditions:default");
        else
            /* updates cmtag */
            /* maps: 'byte' => 'cma'; 'native' => 'cmxa' */
            has_conditions = obzl_meta_flags_to_cmtag(flags, cmtag);

        if (!has_conditions) {
            goto next; /* continue does not seem to exit loop */
        }
        if (settings_ct > 1) {
            if (obzl_meta_values_count(vals) > 0) {
                if (strncmp(utstring_body(cmtag), "cma", 4) == 0) {
                    fprintf(ostream,
                            "        "
                            "\"@rules_ocaml//platform/executor:vm\" :");
                } else {
                    fprintf(ostream,
                            "        "
                            "\"@rules_ocaml//platform/executor:sys\":");

                }
            }
        }
        //else???

        /* now we handle UPDATE settings */
        LOG_DEBUG(0, "setting values:", "");

        /* now we construct a bazel label for each value */
        UT_string *label;
        utstring_new(label);
        /* for archive, should be only 1 value */
        if (obzl_meta_values_count(vals) > 0) {
            for (int j = 0; j < obzl_meta_values_count(vals); j++) {
                archive_name = obzl_meta_values_nth(vals, j);
                LOG_INFO(0, "prop[%d] '%s' == '%s'",
                         j, property, (char*)*archive_name);
                utstring_clear(label);
                if (_pkg_prefix == NULL) {
                    utstring_printf(label, "%s", *archive_name);
                } else {
                    char *start = strchr(_pkg_prefix, '/');
                    if (start == NULL) {
                        utstring_printf(label, "%s", *archive_name);
                    } else {
                        start++;
                        utstring_printf(label, "%s",
                                        *archive_name);
                    }
                }
                // FIXME: verify existence using access()?
                int indent = 3;
                if (strncmp(utstring_body(cmtag), "cmxa", 4) == 0)
                    indent--;
                if (settings_ct > 1) {
                    fprintf(ostream, " \"%s\",\n",
                            utstring_body(label));
                } else {
                    fprintf(ostream, "5) %*s = \"%s\",\n",
                            indent, sp, utstring_body(label));
                }
            }
        }
        utstring_free(label);
    next:
        ;
    }
    fprintf(ostream,
            "    }, no_match_error=\"Bad platform\"),\n");
}

void emit_bazel_cmxs_attr(FILE* ostream,
                          int level, /* indentation control */
                          /* char *_repo, */
                          /* char *_pkg_path, */
                          char *_pkg_prefix,
                          char *_pkg_name,
                          /* for constructing import label: */
                          char *_filedeps_path, /* _lib */
                          /* char *_subpkg_dir, */
                          obzl_meta_entries *_entries,
                          char *property, /* = 'archive' or 'plugin' */
                          obzl_meta_package *_pkg)
{
    TRACE_ENTRY;
    (void)_pkg;
    (void)_pkg_name;
    (void)_filedeps_path;
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, BLU "EMIT_BAZEL_CMXS_ATTR" CRESET, "");
    LOG_DEBUG(0, "\t_pkg_name: '%s'", _pkg_name);
    LOG_DEBUG(0, "\tprop: '%s'", property);
    LOG_DEBUG(0, "\tfiledeps path: '%s'",  _filedeps_path);
    LOG_DEBUG(0, "\tpkg_prefix: %s", _pkg_prefix);
#endif

    struct obzl_meta_property *deps_prop = obzl_meta_entries_property(_entries, property);
    if ( deps_prop == NULL ) {
        LOG_WARN(0, "Prop '%s' not found: %s.", property); //, pkg_name);
        return;
    }

    obzl_meta_settings *settings = obzl_meta_property_settings(deps_prop);

    int settings_ct = obzl_meta_settings_count(settings);
#if defined(PROFILE_fastbuild)
    LOG_INFO(0, "settings count: %d", settings_ct);
#endif
    if (settings_ct == 0) {
#if defined(PROFILE_fastbuild)
        LOG_INFO(0, "No settings for %s", obzl_meta_property_name(deps_prop));
#endif
        return;
    }

    /* dealing with OP_UDATE.
       e.g. ppx_sexp_conv has three settings:
       requires(ppx_driver) = "ppx_sexp_conv.expander ppxlib"
       requires(-ppx_driver) = "ppx_sexp_conv.runtime-lib"
       ppx(-ppx_driver,-custom_ppx) += "ppx_deriving"

       the 3rd must combine the 2nd because the op on the last is '+='
       condition: no_ppx_driver: ppx_sexp_conv.runtime-lib
       condition: no_ppx_driver_no_custom_ppx: ppx_sexp_conv.runtime-lib, ppx_deriving
       if op == UPDATE then for each flag, search flaglist for match and add vals if found
     */

    /* NB: 'property' will be 'archive' or 'plugin' (?) */
    fprintf(ostream, "%*scmxs", level*spfactor, sp);

    UT_string *cmtag;  /* i.e. flag */
    utstring_new(cmtag);

    obzl_meta_setting *setting = NULL;

    obzl_meta_values *vals;
    obzl_meta_value *archive_name = NULL;

    for (int i = 0; i < settings_ct; i++) {
        setting = obzl_meta_settings_nth(settings, i);
        obzl_meta_flags *flags = obzl_meta_setting_flags(setting);
        /* skip any setting with deprecated flag, e.g. 'vm' */
        if (obzl_meta_flags_deprecated(flags)) {
            continue;
        }

        bool has_conditions = false;
        if (flags == NULL)
            utstring_printf(cmtag, "//conditions:default");
        else
            has_conditions = obzl_meta_flags_to_cmtag(flags, cmtag);
        if (!has_conditions) {
            goto next; /* continue does not seem to exit loop */
        }

        /* now we handle UPDATE settings */
        vals = resolve_setting_values(setting, flags, settings);
#if defined(PROFILE_fastbuild)
        LOG_DEBUG(0, "setting values:", "");
#endif
        /* dump_values(0, vals); */

        /* now we construct a bazel label for each value */
        UT_string *label;
        utstring_new(label);

        for (int j = 0; j < obzl_meta_values_count(vals); j++) {
            archive_name = obzl_meta_values_nth(vals, j);
#if defined(PROFILE_fastbuild)
            LOG_INFO(0, "\tprop[%d] '%s' == '%s'",
                     j, property, (char*)*archive_name);
#endif

            utstring_clear(label);
            if (_pkg_prefix == NULL) {
                utstring_printf(label, "%s", *archive_name);
            } else {
                char *start = strchr(_pkg_prefix, '/');
                if (start == NULL) {
                    utstring_printf(label, "%s", *archive_name);
                } else {
                    start++;
                    utstring_printf(label, "%s", *archive_name);
                }
            }
            if (strncmp(utstring_body(cmtag), "cmxa", 4) == 0) {
                fprintf(ostream, " = \"%s\",\n", utstring_body(label));
            }
        }
        utstring_free(label);
    next:
        ;
    }
    utstring_free(cmtag);
}

/*
  FIXME: version, description really apply to whole pkg; put them in comments, not rule attributes
 */
LOCAL void emit_bazel_metadatum(FILE* ostream, int level,
                          char *repo,
                          obzl_meta_entries *_entries,
                          char *_property, // META property
                          char *_attrib    // Bazel attr name
                          )
{
    (void)level;
    (void)repo;
    /* emit version, description properties */

    struct obzl_meta_property *the_prop = obzl_meta_entries_property(_entries, _property);
    if ( the_prop == NULL ) {
        return;
    }

    obzl_meta_settings *settings = obzl_meta_property_settings(the_prop);
    obzl_meta_setting *setting = NULL;

    if (obzl_meta_settings_count(settings) == 0) {
        LOG_INFO(0, "No settings for property '%s'", _property);
        return;
    }
    int settings_ct = obzl_meta_settings_count(settings);
    if (settings_ct > 1) {
        LOG_WARN(0, "settings count > 1 for property '%s'; using the first.", settings_ct, _property);
    }

    obzl_meta_values *vals;
    obzl_meta_value *v = NULL;

    setting = obzl_meta_settings_nth(settings, 0);

    /* should not be any flags??? */

    vals = obzl_meta_setting_values(setting);
    /* dump_values(0, vals); */
    v = obzl_meta_values_nth(vals, 0);
    if (v != NULL)
        fprintf(ostream, "    %s = \"\"\"%s\"\"\",\n",
                _attrib,
                /* _property, */
                *v);
}

LOCAL void emit_bazel_archive_rule(FILE *ostream,
                             char *opam_switch_dir,
                             char *coswitch_pkg_root,
                             char *coswitch_lib,
                             int level,
                             /* char *ws_name, */
                             char *_filedeps_path, /* _lib/... */
                             char *_pkg_root,
                             /* char *_pkg_path, */
                             char *_pkg_prefix,
                             char *obazl_pfx,
                             char *_pkg_name,
                             UT_string *pkg_parent,
                             obzl_meta_entries *_entries, //)
                             /* char *_subpkg_dir) */
                             obzl_meta_package *_pkg)
{
    (void)level;
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, "EMIT_BAZEL_ARCHIVE_RULE: _filedeps_path: %s", _filedeps_path);
#endif
    /* http://projects.camlcity.org/projects/dl/findlib-1.9.1/doc/ref-html/r759.html

The variable "archive" specifies the list of archive files. These files should be given either as (1) plain names without any directory information; they are only searched in the package directory. (2) Or they have the form "+path" in which case the files are looked up relative to the standard library. (3) Or they have the form "@name/file" in which case the files are looked up in the package directory of another package. (4) Or they are given as absolute paths.

The names of the files must be separated by white space and/or commas. In the preprocessor stage, the archive files are passed as extensions to the preprocessor (camlp4) call. In the linker stage (-linkpkg), the archive files are linked. In the compiler stage, the archive files are ignored.

Note that "archive" should only be used for archive files that are intended to be included in executables or loaded into toploops. For modules loaded at runtime there is the separate variable "plugin".
     */

    /* archive flags: byte, native */
    /* pkg threads: mt, mt_vm, mt_posix */
    /* ppx: ppx_driver, -ppx_driver always go together. not a syntactic rule, but seems to be the convention */

    /* _filedeps_path: relative to opam_switch_lib
       we need to convert it to a bazel label
       e.g. ounit2/advanced => @ounit2//advanced
       we do this here because it applies to all props/subpkgs
       BUT: just use pkg_prefix and pkg name?
     */

    //FIXME: only if --enable-jsoo passed
    /* emit_bazel_jsoo(ostream, 1, */
    /*                 _pkg_prefix, */
    /*                 _pkg_name, */
    /*                 /\* for constructing import label: *\/ */
    /*                 _filedeps_path, */
    /*                 /\* _subpkg_dir, *\/ */
    /*                 _entries, */
    /*                 "archive", */
    /*                 _pkg); */

    // do we have any .h files?
    /* char **found; */
    glob_t globs;
    UT_string *globber;
    utstring_new(globber);
    utstring_printf(globber, "%s/%s/*.h", opam_switch_dir, _filedeps_path);
    errno = 0;
    int rc = glob(utstring_body(globber), GLOB_ERR , NULL, &globs);
    if( rc == 0 ) {
        if (globs.gl_pathc > 0) {
            /* fprintf(ostream, "## globbed: %s\n", utstring_body(globber)); */
            fprintf(ostream, "\ncc_library(\n");
            fprintf(ostream, "    name     = \"hdrs\",\n");
            fprintf(ostream, "    hdrs     = glob([\"*.h\"], allow_empty=True),\n");
            fprintf(ostream, "    includes = [\".\"],\n");
            fprintf(ostream, "    deps     = [\"@opam.ocamlsdk//ffi/lib\"],\n");
            fprintf(ostream, ")\n\n");
        }
    } else {
        if( rc == GLOB_NOMATCH ) {
            LOG_DEBUG(0, "glob nomatch: %s", utstring_body(globber));
        } else {
            log_error("Some kinda glob error");
            exit(1);
        }
    }
    utstring_free(globber);

    /* write scheme opam-resolver table */
    fprintf(ostream, "\nocaml_import(\n");
    fprintf(ostream, "    name = \"%s\",\n", _pkg_name); /* default target provides archive */

    emit_bazel_metadatum(ostream, 1,
                         ocaml_ws,              /* @ocaml */
                         /* _filedeps_path, */
                         _entries, "version", "version");
    emit_bazel_metadatum(ostream, 1,
                         ocaml_ws, // "@ocaml",
                         /* _filedeps_path, */
                         _entries, "description", "doc");

    fprintf(ostream, "    sigs     = glob([\"*.cmi\"], allow_empty=True),\n");

    emit_bazel_archive_attr(ostream, 1,
                            _pkg_prefix,
                            _pkg_name,
                            /* for constructing import label: */
                            _filedeps_path,
                            _entries,
                            "archive",
                            _pkg);

    fprintf(ostream,
            "    afiles   = select({\n"
            "        \"@rules_ocaml//platform/executor:vm\" : [],\n"
            "        \"@rules_ocaml//platform/executor:sys\": "
            "glob([\"*.a\"], allow_empty=True, exclude=[\"lib*_stubs.a\"])\n"
            "    }, no_match_error=\"Bad platform\"),\n");

    /* FIXME: 'structs', not 'astructs' -  bazel rule decides what to do */
    //fprintf(ostream, "    astructs = glob([\"*.cmx\"]),\n");
    fprintf(ostream,
            "    astructs = select({\n"
            "        \"@rules_ocaml//platform/executor:vm\" : [],\n"
            "        \"@rules_ocaml//platform/executor:sys\": "
            "glob([\"*.cmx\"], allow_empty=True)\n"
            "    }, no_match_error=\"Bad platform\"),\n");

    /* FIXME: ofiles are never present? */
    //fprintf(ostream, "    ofiles   = glob([\"*.o\"]),\n");
    fprintf(ostream,
            "    ofiles   = select({\n"
            "        \"@rules_ocaml//platform/executor:vm\" : [],\n"
            "        \"@rules_ocaml//platform/executor:sys\": "
            "glob([\"*.o\"], allow_empty=True)\n"
            "    }, no_match_error=\"Bad platform\"),\n");

    fprintf(ostream, "    cmts     = glob([\"*.cmt\"], allow_empty=True),\n");
    fprintf(ostream, "    cmtis    = glob([\"*.cmti\"], allow_empty=True),\n");
    fprintf(ostream, "    dllibs   = glob([\"dll*.so\"], allow_empty=True),\n");
    fprintf(ostream, "    srcs     = glob([\"*.ml\", \"*.mli\"], allow_empty=True),\n");

    //FIXME: only if --enable-jsoo passed
    /* emit_bazel_jsoo_runtime_attr(ostream, 1, */
    /*                              _pkg_root, */
    /*                              _pkg_prefix, */
    /*                              _pkg_name, */
    /*                              pkg_parent, */
    /*                              _filedeps_path, */
    /*                              _entries, */
    /*                              _pkg); */

    /* emit cc_deps attr with lib*stubs.a */
    emit_bazel_stublibs_attr(ostream,
                             coswitch_pkg_root,
                             coswitch_lib,
                             1, /* indent level */
                             _pkg_root,
                             _pkg_prefix,
                             obazl_pfx,
                             _pkg_name,
                             pkg_parent,
                             _filedeps_path,
                             _entries,
                             _pkg);
    emit_bazel_deps_attribute(ostream, 1,
                              false, /* not jsoo */
                              ocaml_ws,
                              "lib",
                              obazl_pfx,
                              _pkg_name,
                              _entries);

    emit_bazel_ppx_codeps(ostream, 1, ocaml_ws, obazl_pfx, _pkg_name, "lib", _entries);
    fprintf(ostream, ")\n");
}

LOCAL void emit_bazel_plugin_rule(FILE* ostream, int level,
                            char *_repo,
                            char *_filedeps_path,
                            /* char *_pkg_path, */
                            char *_pkg_prefix,
                            char *obazl_pfx,
                            char *_pkg_name,
                            obzl_meta_entries *_entries, //)
                            obzl_meta_package *_pkg)
{
    (void)level;
    (void)_repo;
    TRACE_ENTRY;
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, BLU "EMIT_BAZEL_PLUGIN_RULE:" CRESET " _filedeps_path: %s", _filedeps_path);
    LOG_DEBUG(0, "obazl_pfx: %s", _pkg_prefix);
    LOG_DEBUG(0, "_pkg_name: %s", _pkg_name);
    LOG_DEBUG(0, "pkg_name: %s", _pkg->name);
#endif

    fprintf(ostream, "\nocaml_import(\n");
    fprintf(ostream, "    name = \"plugin\",\n");

    emit_bazel_cmxs_attr(ostream, 1,
                         _pkg_prefix,
                         _pkg_name,
                         /* for constructing import label: */
                         _filedeps_path,
                         _entries,
                         "plugin",
                         _pkg);

    emit_bazel_deps_attribute(ostream, 1,
                              false, /* not jsoo */
                              ocaml_ws,
                              "lib",
                              obazl_pfx,
                              _pkg_name,
                              _entries);
    fprintf(ostream, ")\n");
}

/*
  special casing: META with directory starting with '^'
  bigarray, dynlink, str, threads, unix
  also: num, raw-spacetime, stdlib, ocamldoc?
  num is a special case. was part of core distrib, now it's a pkg

  we emit an alias to redirect from standalone to @ocaml
  e.g. @bigarray//bigarray => @ocaml//bigarray/lib

  this is an OPAM legacy thing in case people depend on these pkgs. we
  don't really need to do this since legacy-to-obazl conversion should
  map legacy pkg names correctly. But we do it anyway just in case.
 */

/* FIXME: copy templates instead? */
bool emit_special_case_rule(FILE* ostream,
                                  char *obazl_pfx,
                                  obzl_meta_package *_pkg)
{
    TRACE_ENTRY;
    LOG_TRACE(0, "emit_special_case_rule pkg: %s", _pkg->name);

    if ((strncmp(_pkg->name, "bigarray", 8) == 0)
        && strlen(_pkg->name) == 8) {

        LOG_TRACE(0, "emit_special_case_rule: %s", "bigarrray");

        char *s = "alias(\n"
            "    name = \"bigarray\",\n"
            "    actual = \"@%socamlsdk//bigarray/lib\",\n"
            "    visibility = [\"//visibility:public\"]\n"
            ")\n";
        fprintf(ostream, s, obazl_pfx);
            return true;
    }

    if ((strncmp(_pkg->name, "dynlink", 7) == 0)
        && strlen(_pkg->name) == 7) {
#if defined(PROFILE_fastbuild)
        LOG_TRACE(0, "emit_special_case_rule: %s",  "dynlink");
#endif

        fprintf(ostream, "## special case: dynlink");
        fprintf(ostream, "alias(\n"
                "    name = \"dynlink\",\n"
                "    actual = \"@%socamlsdk//dynlink/lib\",\n"
                "    visibility = [\"//visibility:public\"]\n"
                ")\n", obazl_pfx);
        return true;
    }

    /* WARNING: some META files list 'compiler-libs' as a requirement,
       but the META file for compiler-libs itself lists no content for
       that package, only subpackages compiler-libs.common etc. are
       populated. The official docs indirectly suggest that the base
       pkg is compiler-libs.common, so that's what we do here.
     */

    if ((strncmp(_pkg->name, "compiler-libs", 13) == 0)
        && strlen(_pkg->name) == 13) {
#if defined(PROFILE_fastbuild)
        LOG_TRACE(0, "emit_special_case_rule: %s", "compiler-libs");
#endif

        fprintf(ostream, "alias(\n"
                "    name = \"compiler-libs\",\n"
                "    actual = \"@%socamlsdk//compiler-libs:common\",\n"
                "    visibility = [\"//visibility:public\"]\n"
                ")\n", obazl_pfx);
        return true;
    }

    //FIXME: lib/ctypes/foreign/BUILD.bazel emits only
    // if lib/ctypes-foreign exists
/*     if ((strncmp(_pkg->name, "foreign", 7) == 0) */
/*         && strlen(_pkg->name) == 7) { */
/* #if defined(PROFILE_fastbuild) */
/*         LOG_TRACE(0, "emit_special_case_rule: %s", "ctypes.foreign"); */
/* #endif */

/*         fprintf(ostream, "alias(\n" */
/*                 "    name = \"foreign\",\n" */
/*                 "    actual = \"@ctypes-foreign//ctypes-foreign\",\n" */
/*                 "    visibility = [\"//visibility:public\"]\n" */
/*                 ")\n"); */
/*         return true; */
/*     } */

    if ((strncmp(_pkg->name, "ocamldoc", 8) == 0)
        && strlen(_pkg->name) == 8) {
#if defined(PROFILE_fastbuild)
        LOG_TRACE(0, "emit_special_case_rule: %s", "ocamldoc");
#endif

        fprintf(ostream, "alias(\n"
                "    name = \"ocamldoc\",\n"
                "    actual = \"@%socamlsdk//ocamldoc/lib\",\n"
                "    visibility = [\"//visibility:public\"]\n"
                ")\n", obazl_pfx);
        return true;
    }

    if ((strncmp(_pkg->name, "str", 3) == 0)
        && strlen(_pkg->name) == 3) {
#if defined(PROFILE_fastbuild)
        LOG_TRACE(0, "emit_special_case_rule: %s", "str");
#endif
        fprintf(ostream, "alias(\n"
                "    name = \"str\",\n"
                "    actual = \"@%socamlsdk//str/lib\",\n"
                "    visibility = [\"//visibility:public\"]\n"
                ")\n", obazl_pfx);
        return true;
    }

    if ((strncmp(_pkg->name, "threads", 7) == 0)
        && strlen(_pkg->name) == 7) {
#if defined(PROFILE_fastbuild)
        LOG_TRACE(0, "emit_special_case_rule: %s", "threads");
#endif

        fprintf(ostream, "alias(\n"
                "    name = \"threads\",\n"
                "    actual = \"@%socamlsdk//threads/lib\",\n"
                "    visibility = [\"//visibility:public\"]\n"
                ")\n", obazl_pfx);
        return true;
    }

    if ((strncmp(_pkg->name, "unix", 4) == 0)
        && strlen(_pkg->name) == 4) {
#if defined(PROFILE_fastbuild)
        LOG_TRACE(0, "emit_special_case_rule: %s", "unix");
#endif

        fprintf(ostream, "alias(\n"
                "    name = \"unix\",\n"
                "    actual = \"@%socamlsdk//unix/lib\",\n"
                "    visibility = [\"//visibility:public\"]\n"
                ")\n", obazl_pfx);
        return true;
    }

    return false;
}

/* **************************************************************** */
EXPORT bool special_case_multiseg_dep(FILE* ostream,
                                     char *obazl_pfx,
                                     obzl_meta_value *dep_name,
                                     char *delim1)
{
    if (delim1 == NULL) {
        if (strncmp(*dep_name, "compiler-libs", 13) == 0) {
            fprintf(ostream, "%*s    \"@%socamlsdk//compiler-libs:common\",\n",
                    (1+level)*spfactor, sp, obazl_pfx);
            return true;
        } else {
            if (strncmp(*dep_name, "threads", 13) == 0) {
                fprintf(ostream, "%*s    \"@%socamlsdk//threads/lib\",\n",
                        (1+level)*spfactor, sp,  obazl_pfx);
                return true;
            }
        }
    } else {
        if (strncmp(*dep_name, "compiler-libs/", 14) == 0) {
            fprintf(ostream,
                    "%*s    \"@%socamlsdk//compiler-libs:%s\",\n",
                    (1+level)*spfactor, sp,
                    obazl_pfx, delim1+1);
            return true;
        }

        if (strncmp(*dep_name, "threads/", 8) == 0) {
            /* threads.posix, threads.vm => threads */
            fprintf(ostream, "        \"@%socamlsdk//threads/lib\",\n", obazl_pfx);
            return true;
        }
    }
    return false;
}

EXPORT void emit_bazel_deps_attribute(FILE* ostream, int level,
                                      bool jsoo,
                                      char *repo,
                                      char *pkg,
                                      char *obazl_pfx,
                                      char *pkg_name,
                                      obzl_meta_entries *_entries)
{
    (void)repo;
    (void)pkg_name;
    TRACE_ENTRY_MSG("%s", pkg_name);
    //FIXME: skip if no 'requires' or requires == ''
    char *pname = "requires";
    struct obzl_meta_property *deps_prop = NULL;
    deps_prop = obzl_meta_entries_property(_entries, pname);
    if ( deps_prop == NULL ) return;
    obzl_meta_value ds = obzl_meta_property_value(deps_prop);
    if (ds == NULL) return;

    obzl_meta_settings *settings = obzl_meta_property_settings(deps_prop);
    obzl_meta_setting *setting = NULL;

    int settings_ct = obzl_meta_settings_count(settings);
    int settings_no_ppx_driver_ct = obzl_meta_settings_flag_count(settings, "ppx_driver", false);

    settings_ct -= settings_no_ppx_driver_ct;

    if (settings_ct == 0) {
        LOG_INFO(0, "No deps for %s", obzl_meta_property_name(deps_prop));
        return;
    }
    LOG_INFO(0, "settings_ct: %d", settings_ct);
    obzl_meta_values *vals;
    obzl_meta_value *dep_name_val = NULL;
    char *dep_name;

    if (settings_ct > 1) {
        fprintf(ostream, "%*sdeps = select({\n", level*spfactor, sp);
    } else {
        fprintf(ostream, "%*sdeps = [\n", level*spfactor, sp);
    }

    UT_string *condition_name;
    utstring_new(condition_name);

    for (int i = 0; i < settings_ct; i++) {
        setting = obzl_meta_settings_nth(settings, i);
        LOG_DEBUG(0, "setting %d", i+1);

        obzl_meta_flags *flags = obzl_meta_setting_flags(setting);
        if (flags != NULL) {
            /* register_flags(flags); */
            /* flags_ct = obzl_meta_flags_count(flags); */
        }

        if (obzl_meta_flags_has_flag(flags, "ppx_driver", false)) {
            continue;
        }

        bool has_conditions;
        if (flags == NULL)
            utstring_printf(condition_name, "//conditions:default");
        else
            has_conditions = obzl_meta_flags_to_selection_label(flags, condition_name);

        char *condition_comment = obzl_meta_flags_to_comment(flags);
        /* LOG_DEBUG(0, "condition_comment: %s", condition_comment); */

        /* 'requires' usually has no flags; when it does, empirically we find only */
        /*   ppx pkgs: ppx_driver, -ppx_driver */
        /*   pkg 'batteries': requires(mt) (ocaml 4.x.y) */
        /*   pkg 'num': requires(toploop) */
        /*   pkg 'findlib': requires(toploop), requires(create_toploop) */

        /* Multiple settings on 'requires' means multiple flags; */
        /* empirically, this only happens for ppx packages, typically as */
        /* requires(-ppx_driver,-custom_ppx) */
        /* the (sole?) exception is */
        /*   pkg 'threads': requires(mt,mt_vm), requires(mt,mt_posix) */

        if (settings_ct > 1) {
            fprintf(ostream, "%*s\"X%s%s\": [ ## predicates: %s\n",
                    (1+level)*spfactor, sp,
                    utstring_body(condition_name),
                    (has_conditions)? "" : "",
                    condition_comment);
        }

        vals = resolve_setting_values(setting, flags, settings);
        /* now we handle UPDATE settings */

        LOG_DEBUG(0, "emitting %d vals", obzl_meta_values_count(vals));
        for (int j = 0; j < obzl_meta_values_count(vals); j++) {
            dep_name_val = obzl_meta_values_nth(vals, j);
            dep_name = strdup((char*)*dep_name_val);
            LOG_DEBUG(0, "dep_name: %s", dep_name);

            char *s = (char*)dep_name;
            /* special case: uchar */
            if ((strncmp(s, "uchar", 5) == 0)
                && (strlen(s) == 5)){
                continue;
            }
            while (*s) {
                if(s[0] == '.') {
                    s[0] = '/';
                }
                s++;
            }

            /* emit 'deps' attr labels */

            if (settings_ct > 1) {
                fprintf(ostream, "%*s\"@FIXME: %s//%s\",\n",
                        (2+level)*spfactor, sp, dep_name, pkg);
            } else {
                /* first convert pkg string */
                /* then extract target segment */
                char *delim1 = strchr(dep_name, '/');
                if (delim1 == NULL) {
                    if (special_case_multiseg_dep(ostream, obazl_pfx, &dep_name, delim1))
                        continue;
                    else {
                        /* single-seg pkg, e.g. ptime  */
                        // handle distrib-pkgs: dynlink, str, unix, etc.
                        /* FIXME: obsolete? */
                        if ((strncmp(dep_name, "bigarray", 8) == 0)
                            && strlen(dep_name) == 8) {
                            fprintf(ostream, "%*s\"@%socamlsdk//bigarray/lib\",\n",
                                    (1+level)*spfactor, sp,
                                    obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "str", 3) == 0)
                                && strlen(dep_name) == 3) {
                                fprintf(ostream, "%*s\"@%socamlsdk//str/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "ffi", 3) == 0)
                                && strlen(dep_name) == 3) {
                                fprintf(ostream, "%*s\"@%socamlsdk//ffi/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "dynlink", 7) == 0)
                                && strlen(dep_name) == 7) {
                                fprintf(ostream, "%*s\"@%socamlsdk//dynlink/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "profiling", 9) == 0)
                                && strlen(dep_name) == 9) {
                                fprintf(ostream, "%*s\"@%socamlsdk//profiling/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "ocamldoc", 8) == 0)
                                && strlen(dep_name) == 8) {
                                fprintf(ostream, "%*s\"@%socamlsdk//ocamldoc/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "threads", 7) == 0)
                                && strlen(dep_name) == 7) {
                                fprintf(ostream, "%*s\"@%socamlsdk//threads/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "compiler-libs", 13) == 0)
                                && strlen(dep_name) == 13) {
                                fprintf(ostream, "%*s\"@%socamlsdk//compiler-libs/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else if ((strncmp(dep_name, "unix", 4) == 0)
                                && strlen(dep_name) == 4) {
                                fprintf(ostream, "%*s\"@%socamlsdk//unix/lib\",\n",
                                        (1+level)*spfactor, sp,
                                        obazl_pfx);
                        }
                        else {
                            /* WARNING: for distrib-pkgs, form @opam.ocamlsdk//lib/<pkg>,
                               not @<pkg>//lib/<pkg>
                            */
                            /* if (strncmp("dynlink", dep_name, 7) == 0) */
                            /*     distrib_pkg = true; */
                            /* else */
                            /*     distrib_pkg = false; */
                            fprintf(ostream,
                                    "%*s\"@%s%s//lib\",\n",
                                    (1+level)*spfactor, sp,
                                    (char*)obazl_pfx,
                                    dep_name);
                                    /* distrib_pkg? "ocaml" : dep_name); */
                            /* dep_name, */
                            /* jsoo? ":js" : ""); */
                        }
                        /* } // else */
                    }
                } else {
                    /* multi-seg pkg, e.g. lwt.unix, ptime.clock.os */
                    if (special_case_multiseg_dep(ostream, obazl_pfx, &dep_name, delim1))
                        continue;
                    else {
                        int repo_len = delim1 - (char*)dep_name;
                        fprintf(ostream,
                                "%*s\"@%s%.*s//%s%s/lib\",\n",
                                /* "%*s\"@%s%.*s//lib/%s%s\",\n", */
                                (1+level)*spfactor, sp,
                                obazl_pfx,
                                repo_len,
                                dep_name,
                                delim1+1,
                                jsoo? ":js" : "");
                    }
                }
            }
            free(dep_name);
        }
        if (settings_ct > 1) {
            fprintf(ostream, "%*s],\n", (1+level)*spfactor, sp);
        }
        free(condition_comment);
    }
    utstring_free(condition_name);
    if (settings_ct > 1)
        fprintf(ostream, "%*s}),\n", level*spfactor, sp);
    else
        fprintf(ostream, "%*s],\n", level*spfactor, sp);
}

EXPORT void emit_bazel_ppx_codeps(FILE* ostream, int level,
                                 char *repo,
                                 char *obazl_pfx,
                                 char *_pkg_name,
                                 char *_pkg_prefix,
                                 obzl_meta_entries *_entries)
{
    (void)_pkg_name;
    /* handle both 'ppx_runtime_deps' and 'requires(-ppx_driver)'

       e.g. ppx_sexp_conv has no ppx_runtime_deps property but:
       requires(-ppx_driver) = "ppx_sexp_conv.runtime-lib"

       ppx_bin_prot has both:
       requires(ppx_driver) = "base
                        compiler-libs.common
                        ppx_bin_prot.shape-expander
                        ppxlib
                        ppxlib.ast"
       ppx_runtime_deps = "bin_prot"
       but:
       requires(-ppx_driver) = "bin_prot ppx_here.runtime-lib"
       requires(-ppx_driver,-custom_ppx) += "ppx_deriving"

       and ppx_expect is even worse; in addition to
       requires(ppx_driver) and requires(-ppx_driver), it has
       ppx(-ppx_driver,-custom_ppx) = "./ppx.exe --as-ppx"

       what does it all mean?  who knows.

       we interpret this to mean: if you build (with ocamlfind) with
       predicate -ppx_driver (= NOT ppx_driver), it means you want to
       use the pkg as a regular dependency, not as part of a ppx
       executable. so in that case, you have to add the ppx_codep as a
       normal dep of the file you're compiling. If you were to use
       predicate ppx_driver, it would mean you are using ppx_sexp_conv
       as part of a ppx executable. The assumption then is that the
       build tool (dune) will compile the ppx executable and use it to
       compile the source file, as a kind of atomic operation, so to
       speak, so it must be smart enough to know that the ppx_codep
       (runtime dep) will be needed to compile the source file after
       ppx processing. which implies that the build tool must treat
       the 'requires(-ppx_driver)' value as a (co)dependency even when
       the predicate is ppx_driver. IOW, '-ppx_driver' does not mean
       "only use this if -ppx_driver' is passed"

       fuck. that means we really need two deps, one for ppx and one
       for non-ppx dep. Example: ppx_bin_prot. the META files have
       this comment:
       # This line makes things transparent for people mixing preprocessors
       # and normal dependencies
       requires(-ppx_driver) = "bin_prot ppx_here.runtime-lib"

       meaning we need a target @ppx_bin_prot//foo for using it as a
       "normal" dep, not a ppx dep.

     */

    //FIXME: skip if no 'requires'
    LOG_DEBUG(0, "emit_bazel_ppx_codeps, repo: %s, pfx: %s, pkg: %s",
              repo, _pkg_prefix, _pkg_name);
    struct obzl_meta_property *deps_prop = obzl_meta_entries_property(_entries, "ppx_runtime_deps");
    if ( deps_prop == NULL ) {
        /* char *pkg_name = obzl_meta_package_name(_pkg); */
        LOG_WARN(0, "Prop 'ppx_runtime_deps' not found for pkg: %s.",
                 _pkg_name);
        return;
    }

    obzl_meta_settings *settings = obzl_meta_property_settings(deps_prop);
    obzl_meta_setting *setting = NULL;

    int settings_ct = obzl_meta_settings_count(settings);
    int settings_no_ppx_driver_ct = obzl_meta_settings_flag_count(settings, "ppx_driver", false);

    settings_ct -= settings_no_ppx_driver_ct;

    /* LOG_INFO(0, "settings count: %d", settings_ct); */

    if (settings_ct == 0) {
        LOG_INFO(0, "No deps for %s", obzl_meta_property_name(deps_prop));
        return;
    }

    obzl_meta_values *vals;
    obzl_meta_value *v = NULL;

    if (settings_ct > 1) {
        fprintf(ostream, "%*sppx_codeps = select({\n", level*spfactor, sp);
    } else {
        fprintf(ostream, "%*sppx_codeps = [\n", level*spfactor, sp);
    }

    UT_string *condition_name;
    utstring_new(condition_name);

    for (int i = 0; i < settings_ct; i++) {
        setting = obzl_meta_settings_nth(settings, i);
        obzl_meta_flags *flags = obzl_meta_setting_flags(setting);
        if (flags != NULL) {
            /* register_flags(flags); */
            /* flags_ct = obzl_meta_flags_count(flags); */
        }

        if (obzl_meta_flags_has_flag(flags, "ppx_driver", false)) {
            continue;
        }

        bool has_conditions = false;
        if (flags == NULL)
            utstring_printf(condition_name, "//conditions:default");
        else
            has_conditions = obzl_meta_flags_to_selection_label(flags, condition_name);

        char *condition_comment = obzl_meta_flags_to_comment(flags);
        /* 'requires' usually has no flags; when it does, empirically we find only */
        /*   ppx pkgs: ppx_driver, -ppx_driver */
        /*   pkg 'batteries': requires(mt) */
        /*   pkg 'num': requires(toploop) */
        /*   pkg 'findlib': requires(toploop), requires(create_toploop) */

        /* Multiple settings on 'requires' means multiple flags; */
        /* empirically, this only happens for ppx packages, typically as */
        /* requires(-ppx_driver,-custom_ppx) */
        /* the (sole?) exception is */
        /*   pkg 'threads': requires(mt,mt_vm), requires(mt,mt_posix) */

        if (settings_ct > 1) {
            fprintf(ostream, "%*s\"%s%s\": [ ## predicates: %s\n",
                    (1+level)*spfactor, sp,
                    utstring_body(condition_name),
                    (has_conditions)? "_enabled" : "",
                    condition_comment);
        }

        vals = resolve_setting_values(setting, flags, settings);
        /* now we handle UPDATE settings */
        for (int j = 0; j < obzl_meta_values_count(vals); j++) {
            v = obzl_meta_values_nth(vals, j);
            char *s = (char*)*v;
            while (*s) {
                if(s[0] == '.') {
                    s[0] = '/';
                }
                s++;
            }
            if (settings_ct > 1) {
                fprintf(ostream, "%*s\"FIXME%s//%s/%s\",\n",
                        (2+level)*spfactor, sp,
                        repo, _pkg_prefix, *v);
            } else {
                char *s = (char*)*v;
                char *tmp;
                while(s) {
                    tmp = strchr(s, '/');
                    if (tmp == NULL) break;
                    *tmp = '.';
                    s = tmp;
                }
                /* then extract target segment */
                char * delim1 = strchr(*v, '.');

                if (delim1 == NULL) {
                    if (special_case_multiseg_dep(ostream, obazl_pfx, v, delim1))
                        continue;
                    else {
                    int repo_len = strlen((char*)*v);
                    fprintf(ostream,
                            "%*s\"@%s%.*s//lib\",\n",
                            (1+level)*spfactor, sp,
                            obazl_pfx,
                            repo_len,
                            *v); // *v);
                    }
                } else {
                    if (special_case_multiseg_dep(ostream, obazl_pfx, v, delim1))
                        continue;
                    else {
                        //first the repo string
                        int repo_len = delim1 - (char*)*v;
                        fprintf(ostream,
                                "%*s\"@%s%.*s/",
                                (1+level)*spfactor, sp,
                                obazl_pfx,
                                repo_len, *v);
                        // then the pkg:target
                        char *s = (char*)delim1;
                        char *tmp;
                        while(s) {
                            tmp = strchr(s, '.');
                            if (tmp == NULL) break;
                            *tmp = '/';
                            s = tmp;
                        }
                        fprintf(ostream, "%s/lib\",\n", delim1);
                    }
                }
            }
        }
        if (settings_ct > 1) {
            fprintf(ostream, "%*s],\n", (1+level)*spfactor, sp);
        }
        free(condition_comment);
    }
    utstring_free(condition_name);
    if (settings_ct > 1)
        fprintf(ostream, "%*s}),\n", level*spfactor, sp);
    else
        fprintf(ostream, "%*s],\n", level*spfactor, sp);
}

/* The variable "directory" redefines the location of the package directory. Normally, the META file is the first file read in the package directory, and before any other file is read, the "directory" variable is evaluated in order to see if the package directory must be changed. The value of the "directory" variable is determined with an empty set of actual predicates. The value must be either: an absolute path name of the alternate directory, or a path name relative to the stdlib directory of OCaml (written "+path"), or a normal relative path name (without special syntax). In the latter case, the interpretation depends on whether it is contained in a main or sub package, and whether the standard repository layout or the alternate layout is in effect (see site-lib for these terms). For a main package in standard layout the base directory is the directory physically containing the META file, and the relative path is interpreted for this base directory. For a main package in alternate layout the base directory is the directory physically containing the META.pkg files. The base directory for subpackages is the package directory of the containing package. (In the case that a subpackage definition does not have a "directory" setting, the subpackage simply inherits the package directory of the containing package. By writing a "directory" directive one can change this location again.) */
/*     *\/ */

/*
  A "deps target" is one that has a 'deps' attribute but no other that
  provides output (i.e. no 'archive' or 'plugin'). Some packages are
  there for compatibility; their resources have been migrated to the
  OCaml distrib. They contain something like 'version = "[distributed
  with Ocaml]"'. Some of these can be treated like normal packages:
  they have 'requires' and/or 'plugin', and a 'directory' property
  redirecting to stdlib, i.e. '^' or leading '+'. So they require no
  special handling (e.g. bigarray). Others may omit 'directory' and
  have no 'archive' or 'plugin' properties; but they do have
  'requires', so we need to emit a target for pkgs depending on them.
 */
void emit_bazel_deps_target(FILE* ostream, int level,
                                  char *_repo,
                                  /* char *_pkg_prefix, */
                                  /* char *_pkg_path, */
                                  char *obazl_pfx,
                                  char *_pkg_name,
                                  obzl_meta_entries *_entries)
{
    TRACE_ENTRY;
    (void)level;
    LOG_DEBUG(0, "DUMMY %s", _pkg_name);

    fprintf(ostream, "## empty targets, in case they are deps of some other target\n");

    /* sorry, special findlib hack: */
    if (strncmp(_pkg_name, "findlib", 7) == 0) {
        fprintf(ostream,
                "\nalias(\n"
                "    name   = \"lib\",\n"
                "    actual = \"@%sfindlib//internal/lib\",\n"
                ")\n", obazl_pfx);

        fprintf(ostream, "\nalias(\n");
        fprintf(ostream, "    name   = \"findlib\",\n");
        fprintf(ostream, "    actual = \"@%sfindlib//internal/lib\",\n", obazl_pfx);
        fprintf(ostream, ")\n");
    } else {
        fprintf(ostream,
                "\nalias(\n"
                "    name   = \"lib\",\n"
                "    actual = \"%s\"\n"
                ")\n", _pkg_name);
        fprintf(ostream, "\nocaml_import(\n");
        fprintf(ostream, "    name = \"%s\",\n", _pkg_name);
        emit_bazel_metadatum(ostream, 1,
                             _repo, _entries,
                             "version", "version");
        emit_bazel_metadatum(ostream, 1,
                             _repo, _entries,
                             "description", "doc");
        emit_bazel_deps_attribute(ostream, 1,
                                  false, /* not jsoo */
                                  ocaml_ws, "lib",
                                  obazl_pfx, _pkg_name,
                                  _entries);
        fprintf(ostream, ")\n");
    }

    //FIXME: only if --enable-jsoo passed
    /* fprintf(ostream, "\njsoo_library(name = \"js\")\n"); */
}

/*
  A small number of META packages are there just to throw an error;
  for example, core.syntax.
 */
void emit_bazel_error_target(FILE* ostream, int level,
                                   char *_repo,
                                   char *_pkg_src,
                                   char *obazl_pfx,
                                   char *_pkg_name,
                                   obzl_meta_entries *_entries)
{
    TRACE_ENTRY;
    (void)level;
    (void)_pkg_src;
    LOG_DEBUG(0, "ERROR TARGET: %s", _pkg_name);
    fprintf(ostream, "\nocaml_import( # error\n");
    fprintf(ostream, "    name = \"%s%s\",\n",
            obazl_pfx, _pkg_name);
    emit_bazel_metadatum(ostream, 1,
                         _repo,
                         /* _pkg_path, */
                         _entries, "version", "version");
    emit_bazel_metadatum(ostream, 1,
                         _repo, // "@ocaml",
                         /* _pkg_path, */
                         _entries, "description", "doc");
    emit_bazel_metadatum(ostream, 1,
                         _repo,
                         /* _pkg_path, */
                         _entries, "error", "error");

    /* fprintf(ostream, "    visibility = [\"//visibility:public\"]\n"); */
    fprintf(ostream, ")\n");
}

// FIXME: most of this duplicates emit_bazel_deps_attribute
LOCAL int newlevel = 0;

LOCAL void emit_bazel_subpackages(// char *ws_name,
                            UT_string *opam_switch_lib,
                            char *coswitch_lib,
                            char *coswitch_pkg_root,
                            int level,
                            char *_pkg_root,
                            UT_string *pkg_parent,
                            char *_pkg_suffix,
                            char *_filedeps_path,
                            char *obazl_pfx,
                            struct obzl_meta_package *_pkg)
{
    (void)level;
    TRACE_ENTRY;
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, BLU "EMIT_BAZEL_SUBPACKAGES" CRESET " pkg: %s", _pkg->name);
    /* LOG_DEBUG(0, "\tws_name: %s", ws_name); */
    LOG_DEBUG(0, "\t_coswitch_lib: %s", coswitch_lib);
    LOG_DEBUG(0, "\tlevel: %d", level);
    LOG_DEBUG(0, "\t_pkg_root: %s", _pkg_root);
    LOG_DEBUG(0, "\t_pkg_parent: %s", utstring_body(pkg_parent));
    LOG_DEBUG(0, "\t_pkg_suffix: %s", _pkg_suffix); //, _pkg_path);
    LOG_DEBUG(0, "\t_filedeps_path: %s", _filedeps_path);
#endif

    obzl_meta_entries *entries = _pkg->entries;
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, "entries ct: %d", obzl_meta_entries_count(entries));
#endif

    obzl_meta_entry *entry = NULL;

    char *pkg_name = obzl_meta_package_name(_pkg);
    UT_string *_new_pkg_suffix;
    utstring_new(_new_pkg_suffix);
    if (_pkg_suffix == NULL)
        utstring_printf(_new_pkg_suffix, "%s", pkg_name);
    else {
        utstring_printf(_new_pkg_suffix, "%s/%s", _pkg_suffix, pkg_name);
    }

    char *curr_parent = strdup(utstring_body(pkg_parent));
    newlevel++;
    if (newlevel > 1) {
        utstring_printf(pkg_parent, "%s", pkg_name);
    } else {
        utstring_printf(pkg_parent, "./");
    }

    LOG_DEBUG(0, "starting level: %d", newlevel);
    for (int i = 0; i < obzl_meta_entries_count(entries); i++) {
        entry = obzl_meta_entries_nth(entries, i);
        if (entry->type == OMP_PACKAGE) {
            obzl_meta_package *subpkg = entry->package;
            emit_build_bazel(opam_switch_lib,
                             coswitch_lib,
                             coswitch_pkg_root,
                             newlevel,
                             _pkg_root, /* pkg_name */
                             pkg_parent,
                             utstring_body(_new_pkg_suffix),
                             _filedeps_path,
                             obazl_pfx,
                             subpkg);
        }
    }
#if defined(PROFILE_fastbuild)
    LOG_DEBUG(0, "Finished level: %d", newlevel);
#endif
    /*  restore */
    newlevel--;
    utstring_renew(pkg_parent);
    utstring_printf(pkg_parent, "%s", curr_parent);
    free(curr_parent);

    utstring_free(_new_pkg_suffix);
    TRACE_EXIT;
}

#ifdef FOO
LOCAL void handle_directory_property(FILE* ostream, int level,
                               char *_repo,
                               char *_pkg_src,
                               char *_pkg_name,
                               obzl_meta_entries *_entries)

{
    (void)_entries;
    (void)level;
    (void)ostream;
    (void)_pkg_name;
    (void)_pkg_src;
    (void)_repo;
    /*
The variable "directory" redefines the location of the package directory. Normally, the META file is the first file read in the package directory, and before any other file is read, the "directory" variable is evaluated in order to see if the package directory must be changed. The value of the "directory" variable is determined with an empty set of actual predicates. The value must be either: an absolute path name of the alternate directory, or a path name relative to the stdlib directory of OCaml (written "+path"), or a normal relative path name (without special syntax). In the latter case, the interpretation depends on whether it is contained in a main or sub package, and whether the standard repository layout or the alternate layout is in effect (see site-lib for these terms). For a main package in standard layout the base directory is the directory physically containing the META file, and the relative path is interpreted for this base directory. For a main package in alternate layout the base directory is the directory physically containing the META.pkg files. The base directory for subpackages is the package directory of the containing package. (In the case that a subpackage definition does not have a "directory" setting, the subpackage simply inherits the package directory of the containing package. By writing a "directory" directive one can change this location again.)
    */

    /*
      IOW, the 'directory' property tells us where 'archive' and
      'plugin' files are to be found. Does not affect interpretation
      of 'requires' property (I think).
     */
    /*
      Directory '^' means '@rules_ocaml//cfg/lib/ocaml'. problem
      is lib/ocaml has no META file; it's the stdlib, always included.
      what about subdirs like 'threads' or 'integers'?

      If directory starts with '+', pkg is relative to '@rules_ocaml//cfg/lib/ocaml'. problem
      is lib/ocaml has no META file; it's the stdlib, always included.
      what about subdirs like 'threads' or 'integers'?
    */

    /* should have one setting */
    /* char *dir = (char*)*obzl_meta_property_value(e->property); */

    /*
      Special cases: ^, +
    */

}
#endif

EXPORT void emit_module_file(UT_string *module_file,
                             char *obazl_pfx,
                             struct obzl_meta_package *_pkg,
                             struct obzl_meta_package *_pkgs)
{
    (void)_pkgs;
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
    /* if (alias) { */
    /*     fprintf(ostream, "    name = \"%s\",\n", _pkg->module_name); */
    /* } else { */
    fprintf(ostream, "    name = \"%s%s\",\n",
            obazl_pfx, _pkg->module_name);
    /* } */
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
    fprintf(ostream, "\n");

    // get **repo** deps: direct deps of pkg and all subpkgs
    if (pkg_deps) {
        p = NULL;
        /* struct obzl_meta_package *pkg; */
        /* LOG_DEBUG(0, "HASH CT: %d", HASH_COUNT(_pkgs)); */
        /* exit(0); */
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
                fprintf(ostream, "bazel_dep(name = \"%s%s\", version = \"%s\") # %s\n", obazl_pfx, *p,
                        default_version, version);
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
                        fprintf(ostream, "bazel_dep(name = \"%s%s\", version = \"%s\")\n",
                                obazl_pfx, *p, default_version);
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

EXPORT void emit_pkg_symlinks(UT_string *opam_switch_lib,
                              UT_string *dst_dir,
                              UT_string *src_dir,
                              char *pkg_name)
{
    TRACE_ENTRY_MSG("pkg name: %s", pkg_name);
    LOG_DEBUG(0, "\tpkg_symlinks src_dir: %s", utstring_body(src_dir));
    LOG_DEBUG(0, "\tpkg_symlinks dst_dir: %s", utstring_body(dst_dir));

    UT_string *opamdir;
    utstring_new(opamdir);
    utstring_printf(opamdir, "%s/%s",
                    utstring_body(opam_switch_lib),
                    utstring_body(src_dir)
                    );

    UT_string *src;
    utstring_new(src);
    UT_string *dst;
    utstring_new(dst);
    int rc;

    LOG_DEBUG(0, "opening src_dir for read: %s", utstring_body(opamdir));
    DIR *d = opendir(utstring_body(opamdir));
    if (d == NULL) { // inaccessible
        if (strncmp(pkg_name, "care", 4) == 0) {
            if (strncmp(utstring_body(src_dir),
                        "topkg/../topkg-care",
                        19) == 0) {
                LOG_DEBUG(0, "Skipping missing %s", "'topkg-care'");
                if (verbosity > 2)
                    log_info("Skipping missing pkg: %s", "'topkg-care'");
                return;
            }
        } else if (strncmp(pkg_name, "configurator", 12) == 0) {
            char *s = utstring_body(opamdir);
            int len = strlen(s);
            char *ptr = s + len - 21;
            /* LOG_INFO(0, "XXXX src_dir: %s", s); */
            /* LOG_INFO(0, "XXXX configurator len: %d", len); */
            /* LOG_INFO(0, "XXXX configurator ptr: %s", ptr); */
            if (len > 20) {
                if (strncmp(ptr, "lib/dune/configurator", 21) == 0) {
                    if (verbosity > 2) {
                        LOG_WARN(0, "Skipping dune/configurator; use @dune-configurator instead.", "");
                    }
                    return;
                } else {
                    LOG_ERROR(0, "MISMATCH dune/configurator", "");
                    exit(0);
                }
            }
        } else {
            LOG_WARN(0, "pkg_symlinks: Unable to opendir %s",
                     utstring_body(opamdir));
        }
        /* this can happen if a related pkg is not installed */
        /* example, see topkg and topkg-care */

        return;
    }

    struct dirent *direntry;
    while ((direntry = readdir(d)) != NULL) {
        //Condition to check regular file.
        if(direntry->d_type==DT_REG){ // or symlink?
            if (strncmp(direntry->d_name, "WORKSPACE", 9) == 0) {
                continue;
            }
            /* LOG_DEBUG(0, "DIRENTRY: %s", direntry->d_name); */
            utstring_renew(src);
            utstring_printf(src, "%s/%s",
                            utstring_body(opamdir), direntry->d_name);
            utstring_renew(dst);
            utstring_printf(dst, "%s/%s",
                            utstring_body(dst_dir), direntry->d_name);
                            /* "%s/%s/%s", */
                            /* utstring_body(dst_dir), */
                            /* pkg_name, */
                            /* direntry->d_name); */
            /* LOG_DEBUG(0, "Symlinking %s => %s", */
            /*           utstring_body(src), utstring_body(dst)); */
            rc = symlink(utstring_body(src),
                         utstring_body(dst));
            if (rc != 0) {
                if (errno != EEXIST) {
                    perror("symlinking");
                    fprintf(stderr, "%s:%d exiting\n", __FILE__, __LINE__);
                    exit(EXIT_FAILURE);
                }
            }
            symlink_ct++;
        }
    }
    closedir(d);
    TRACE_EXIT;
}

/*
  params:
  ws_name: "ocaml"
  coswitch_lib:
  _tgtroot: output dir

  _pkg_prefix - result of concatenating ancestors up to parent; starts
                with bzl_lib (default: "lib")

  pkg path will be made by concatenating _pkg_prefix to pkg name

  pending/completed deps: used to avoid duplication of effort. When
  retrieving list of deps for a pkg, we check to see if its already
  been processed, or if its already in the list of pending deps. If
  neither, we add it to pending deps.
 */
/* FIXME: refactor this monster function */
EXPORT void emit_build_bazel(UT_string *opam_switch_lib,
                             char *coswitch_lib,
                             char *coswitch_pkg_root,
                             int level,
                             char *_pkg_name,
                             UT_string *pkg_parent,
                             char *_pkg_suffix,
                             char *_filedeps_path,
                             char *obazl_pfx,
                             struct obzl_meta_package *_pkg)
{
    TRACE_ENTRY;
    /* ENTRY */
    LOG_INFO(0, "\tpkg: %s", obzl_meta_package_name(_pkg));
    LOG_INFO(0, "\tcoswitch_lib: %s", coswitch_lib);
    LOG_INFO(0, "\tcoswitch_pkg_root: %s", coswitch_pkg_root);
    LOG_INFO(0, "\tpkg->name: %s", obzl_meta_package_name(_pkg));
    LOG_INFO(0, "\t_pkg_name: %s", _pkg_name);
    LOG_INFO(0, "\tlevel: %d", level);
    LOG_INFO(0, "\tpkg_parent: '%s'", utstring_body(pkg_parent));
    LOG_INFO(0, "\t_pkg_suffix: '%s'", _pkg_suffix);
    LOG_INFO(0, "\t_filedeps_path: %s", _filedeps_path);
    /* dump_package(0, _pkg); */

    if (strncmp(_pkg->name, "compiler-libs", 13) == 0) {
        /* handled separately */
        return;
    }

    char *pkg_name = obzl_meta_package_name(_pkg);
    utstring_renew(bazel_repo_name);
    utstring_renew(build_bazel_file);

    /* LOG_DEBUG(0, "build_bazel_file: %s", utstring_body(build_bazel_file)); */
    /* WARNING: pkg may be empty (no entries) */
    /* e.g. js_of_ocaml contains: package "weak" ( ) */
    obzl_meta_entries *entries = _pkg->entries;
    UT_string *new_filedeps_path = NULL;
    utstring_renew(new_filedeps_path);
    char *directory = obzl_meta_directory_property(entries);
    LOG_DEBUG(0, "DIRECTORY property: '%s'", directory);
    if ( directory == NULL ) {
        /* directory omitted or directory = "" */
        /* if (_filedeps_path != NULL) */
        utstring_printf(new_filedeps_path, "%s", _filedeps_path);
    } else {
        /* utstring_printf(build_bazel_file, "/%s", subpkg_dir); */
        if ( strncmp(directory, "+", 1) == 0 ) {
            LOG_DEBUG(0, "BBBB", "");
            /* Initial '+' means 'relative to stdlib dir', i.e. these
               are libs found in lib/ocaml. used by: compiler-libs, ?
               subdirs of lib/ocaml: stublibs, caml, compiler-libs,
               threads, threads/posix, ocamldoc.
            */
            /* stdlib = true; */
            LOG_DEBUG(0, "Found STDLIB directory '%s' for %s", directory, pkg_name);
            directory++;
            utstring_printf(new_filedeps_path, "ocaml/%s", directory);
            /* utstring_printf(new_filedeps_path, "_lib/ocaml/%s", directory); */
        } else {
            if (strncmp(directory, "^", 1) == 0) {
                LOG_DEBUG(0, "STDLIB REDIRECT ^", "");
                /* Initial '^' means pkg within stdlib, i.e.
                   lib/ocaml; "Only included because of
                   findlib-browser" or "distributed with Ocaml". only
                   applies to: raw-spacetime, num, threads, bigarray,
                   unix, stdlib, str, dynlink, ocamldoc.
                   (but num split out of distrib with 4.06.0)
                   for <5.0.0, in the opam
                   repo these only have a META file, which redirects
                   to files or subdirs in lib/ocaml.
                   for >=5.0.0, these have no toplevel dir w/META;
                   instead they have a subdir w/META inside lib/ocaml,
                   which does not use '^'
                */
                /* stdlib = true; */
                directory++;
                /* stdlib_root = true; */
                if (strlen(directory) == 1)
                    utstring_printf(new_filedeps_path,
                                    "%socamlsdk",
                                    obazl_pfx);
                else
                    utstring_printf(new_filedeps_path,
                                    "%socamlsdk/%s",
                                    obazl_pfx, directory);
                /* utstring_printf(new_filedeps_path, "_lib/%s", "ocaml"); */
                LOG_DEBUG(0, "Found STDLIB root directory for %s: '%s' => '%s'",
                          pkg_name, directory, utstring_body(new_filedeps_path));
            } else {
                utstring_printf(new_filedeps_path,
                                "%s/%s", _filedeps_path, directory);
            }
        }
    }
    LOG_DEBUG(0, "new_filedeps_path: %s", utstring_body(new_filedeps_path));

    utstring_renew(bazel_repo_name); /* OUTPUT dir */
    utstring_printf(bazel_repo_name,
                    "%s",  // "%s/lib",
                    coswitch_pkg_root);

    utstring_renew(bazel_pkg_label);
    if (level > 0) {
        /* mtime.clock    => @opam.mtime//clock/lib
           mtime.clock.os => @opam.mtime//clock/os/lib */
        utstring_printf(bazel_pkg_label,
                        "%s/%s/%s/lib",
                        utstring_body(pkg_parent),
                        utstring_body(bazel_repo_name),
                        _pkg->name);

        /* utstring_printf(bazel_repo_name, */
        /*                 "/%s", */
        /*                 utstring_body(pkg_parent)); */
        /* log_debug("PARENT %s", utstring_body(bazel_repo_name)); */
    } else {
        utstring_printf(bazel_pkg_label,
                        "%s/lib", utstring_body(bazel_repo_name));
    }
    mkdir_r(utstring_body(bazel_pkg_label));

    utstring_renew(build_bazel_file);
    utstring_printf(build_bazel_file,
                    "%s/BUILD.bazel",
                    utstring_body(bazel_pkg_label));

                    /* "%s/%s", */
                    /* utstring_body(bazel_repo_name), */
                    /* pkg_name); */
    /* utstring_printf(build_bazel_file, "/%s", "BUILD.bazel"); */

    LOG_DEBUG(0, "bazel_repo_name: %s", utstring_body(bazel_repo_name));
    LOG_DEBUG(0, "bazel_pkg_label: %s", utstring_body(bazel_pkg_label));
    LOG_DEBUG(0, CYN "build_bazel_file:" CRESET, "");
    LOG_DEBUG(0, CYN "\t%s" CRESET, utstring_body(build_bazel_file));

    errno = 0;
    int rc = access(utstring_body(build_bazel_file), F_OK);
    if (rc == 0) {
        /* OK - file already exists from previous run */
    } else {
        /* log_debug("NOT FOUND: %s", utstring_body(build_bazel_file)); */
    }
    LOG_DEBUG(0, "fopening for write: %s", utstring_body(build_bazel_file));

    FILE *ostream;
    ostream = fopen(utstring_body(build_bazel_file), "w");
    if (ostream == NULL) {
        perror(utstring_body(build_bazel_file));
        LOG_ERROR(0, "fopen failure for %s", utstring_body(build_bazel_file));
        exit(EXIT_FAILURE);
    }

    /* SPECIAL CASE HANDLING
       < 5.0.0 : toplevel num, bigarray, unix, threads,
       str, ocamldoc, dynlink

       >= 5.0.0 : no META files for the builtin libs dynlink, str, etc.
     */
    /* if ((_pkg_suffix == NULL) */
    /*     || ((strncmp(_pkg_suffix, "ocaml", 5) == 0) )) { */
    if ((strncmp(_pkg_name, "ocaml", 5) == 0)) {
            /* && (strlen(_pkg_suffix) == 5))) */
        if (emit_special_case_rule(ostream, obazl_pfx, _pkg)) {
            LOG_TRACE(0, "+emit_special_case_rule:TRUE", "");
            LOG_TRACE(0, "\tpkg suffix: %s", _pkg_suffix);
            LOG_TRACE(0, "\tpkg name: %s", _pkg->name);
            return;
            /* LOG_TRACE(0, "-emit_special_case_rule:FALSE %s", _pkg->name); */
        }
    }

    /* if (strncmp(_pkg_name, "ctypes", 6) == 0) { */
    /*     if (strncmp(_pkg->name, "foreign", 7) == 0) { */
    /*         if (emit_special_case_rule(ostream, obazl_pfx, _pkg)) */
    /*             { */
    /*                 return; */
    /*             } */
    /*     } */
    /* } */

    emit_pkg_symlinks(opam_switch_lib,
                      /* bazel_repo_name, /\* dest *\/ */
                      bazel_pkg_label,
                      new_filedeps_path, /* src */
                      pkg_name);

    fprintf(ostream, "## generated file - DO NOT EDIT\n");

    fprintf(ostream, "## original: %s\n\n", obzl_meta_package_src(_pkg));

    /*FIXME: META file does not contain info about executables
      generated by dune-package. E.g. ppx_tools. So we can't emit
      target code for them. For now we just export everything.

      options: iterate over files and pick out executables; or parse
      the dune-package file.
    */
    fprintf(ostream, "package(default_visibility=[\"//visibility:public\"])\n");
    fprintf(ostream, "exports_files(glob([\"**\"]))\n\n");

    emit_bazel_hdr(ostream); //, 1, ocaml_ws, "lib", _pkg);

    /* special case (why?) */
    /* if ((strncmp(pkg_name, "ctypes", 6) == 0) */
    /*     && strlen(pkg_name) == 6) { */
    /* } */

    /* special case (why?) */
    if ((strncmp(pkg_name, "cstubs", 6) == 0)
        && strlen(pkg_name) == 6) {
        /* "load(\"@rules_cc//cc:defs.bzl\", \"cc_library\")\n" */
        fprintf(ostream,
                "cc_library(\n"
                "    name = \"hdrs\",\n"
                /* "    srcs = glob([\"*.a\"]),\n" */
                "    hdrs = glob([\"*.h\"], allow_empty=True),\n"
                /* "    visibility = [\"//visibility:public\"],\n" */
                ")\n");
    }

    emit_bazel_cc_imports(ostream, 1,
                          _pkg_suffix,
                          pkg_name,
                          _filedeps_path,
                          entries,
                          _pkg);

    obzl_meta_entry *e = NULL;
    if (_pkg->entries == NULL) {
        LOG_DEBUG(0, "EMPTY ENTRIES", "");
    } else {
        for (int i = 0; i < obzl_meta_entries_count(_pkg->entries); i++) {
            e = obzl_meta_entries_nth(_pkg->entries, i);
            /*
              FIXME: some packages use plugin or toploop flags in an
              'archive' property. We need to check the archive property,
              and if this is the case, generate separate import targets
              for them. Unlike findlib we do not use flags to select the
              files we want; instead we expose everything using
              ocaml_import targets.
            */

            if (e->type == OMP_PROPERTY) {
                /* 'library_kind` :=  'ppx_deriver' or 'ppx_rewriter' */
                if (strncmp(e->property->name, "archive", 7)
                    == 0) {
                    if ((strlen(pkg_name) != 3)
                        || (strncmp(pkg_name, "lib", 3) != 0)) {
                        fprintf(ostream,
                                "\nalias(\n"
                                "    name   = \"lib\",\n"
                                "    actual = \"%s\"\n"
                                ")\n", pkg_name);
                    }
                    emit_bazel_archive_rule(ostream,
                                            utstring_body(opam_switch_lib),
                                            coswitch_pkg_root,
                                            coswitch_lib,
                                            1, /* indent level */
                                            utstring_body(new_filedeps_path),
                                            _pkg_name,
                                            _pkg_suffix,
                                            obazl_pfx,
                                            pkg_name,
                                            pkg_parent,
                                            entries, //);
                                            _pkg);
                    continue;
                }
                else if (strncmp(e->property->name, "plugin", 6) == 0) {
                    emit_bazel_plugin_rule(ostream, 1,
                                           ocaml_ws,
                                           utstring_body(new_filedeps_path),
                                           _pkg_suffix,
                                           obazl_pfx,
                                           pkg_name,
                                           entries, //);
                                           _pkg);
                    continue;
                }
                /* at this point we've processed archive and plugin props.
                   now we handle pkgs that have deps ('requires') but do
                   not deliver any files ('archive' or 'plugin').
                */

                else if (strncmp(e->property->name, "requires", 6)
                    == 0) {
                    /* some pkgs have 'requires' but no 'archive' nor 'plugin' */
                    /* compiler-libs has 'requires = ""' and 'director = "+compiler-libs"' */
                    /* ppx packages have 'requires(ppx_driver)' and 'requires(-ppx_driver)' */

                    /* we should've already handled these 2: */
                    if (obzl_meta_entries_property(entries, "archive"))
                        continue;
                    if (obzl_meta_entries_property(entries, "plugin"))
                        continue;

                    /* compatibility pkgs whose resources are now
                       'distributed with OCaml' may not have 'archive' or
                       'plugin', but we still need to generate a target,
                       since they have deps ('requires') that legacy code
                       may depend on. */

                    /* UPDATE: we now generate the standard dummy pkgs
                       like bigarray and threads using a repo rule */
                    emit_bazel_deps_target(ostream, 1, ocaml_ws,
                                           obazl_pfx, pkg_name, entries);
                    continue;
                }
                else if (strncmp(e->property->name, "description", 11)
                    == 0) {
                    // ignore, handled elsewhere
                }
                else if (strncmp(e->property->name, "version", 7)
                    == 0) {
                    // ignore, handled elsewhere
                }
                else if (strncmp(e->property->name, "warning", 7)
                    == 0) {
                    LOG_INFO(0, "processing 'warning' property", "");
                    // FIXME: emit comment?
                }
                else if (strncmp(e->property->name, "exists_if", 9)
                    == 0) {
              LOG_INFO(0, "processing 'exists_if' property", "");
                }
                else if (strncmp(e->property->name, "exports", 7)
                    == 0) {
              LOG_INFO(0, "processing 'exports' property", "");
                }
                /* **************** */
                //TODO:FIXME: only if --enable-jsoo passed
                /* if (strncmp(e->property->name, "jsoo_runtime", 12) == 0) { */
                /*     obzl_meta_value ds = obzl_meta_property_value(e->property); */
                /*     fprintf(ostream, "\njsoo_import(\n"); */
                /*     fprintf(ostream, "    name = \"jsoo_runtime\",\n"); */
                /*     fprintf(ostream, "    src = \"%s\",\n", (char*)ds); */
                /*     fprintf(ostream, ")\n"); */
                /* } */

                else if (obzl_meta_entries_property(entries, "error")) {
                    emit_bazel_error_target(ostream, 1, ocaml_ws,
                                            "FIXME_ERROR",
                                            obazl_pfx,
                                            pkg_name, entries);
                    break;
                }
                else {
                    LOG_WARN(0, "processing other property: %s", e->property->name);
                }
                /* dump_entry(0, e); */
                // push all flags to global pos_flags
            }
        }
    }
    /* emit_bazel_flags(ostream, coswitch_lib, ws_name, _pkg_suffix, _pkg); */

    fclose(ostream);

    if (verbosity > log_writes) {
        fprintf(INFOFD, GRN "INFO" CRESET
                " wrote: %s\n", utstring_body(build_bazel_file));
    }

    if (_pkg->entries != NULL) {
        emit_bazel_subpackages(opam_switch_lib,
                               coswitch_lib,
                               coswitch_pkg_root,
                               level,
                               _pkg_name,
                               pkg_parent,
                               _pkg_suffix,
                               utstring_body(new_filedeps_path),
                               obazl_pfx,
                               _pkg);
    }
}
