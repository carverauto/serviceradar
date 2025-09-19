#include <errno.h>

#include "liblogc.h"
#include "findlibc.h"
#include "utstring.h"

#include "registry.h"

#define DEBUG_LEVEL coswitch_debug
extern int  DEBUG_LEVEL;
#define TRACE_FLAG coswitch_trace
extern bool TRACE_FLAG;

void _emit_reg_rec(UT_string *reg_file, char *pkg_name)
{
    TRACE_ENTRY;
    FILE *ostream;
    ostream = fopen(utstring_body(reg_file), "w");
    if (ostream == NULL) {
        log_error("%s", strerror(errno));
        perror(utstring_body(reg_file));
        exit(EXIT_FAILURE);
    }

    fprintf(ostream, "## generated file - DO NOT EDIT\n\n");

    /* always set ocaml and stublibs version to 0.0.0
       that way using another switch does not require
       a change to the ocaml bazel_dep
    */
    fprintf(ostream, "module(\n");
    fprintf(ostream, "    name = \"%s\", version = \"%s\",\n",
            pkg_name,
            default_version
            );
    fprintf(ostream, "    compatibility_level = %d,\n",
            default_compat);
    fprintf(ostream, "    bazel_compatibility = [\">=%s\"]\n",
            bazel_compat);
    fprintf(ostream, ")\n");
    fprintf(ostream, "\n");
    if (strncmp("ocaml", pkg_name, 5) == 0) {
        fprintf(ostream,
                "bazel_dep(name = \"platforms\", version = \"%s\")\n", platforms_version);
        fprintf(ostream,
                "bazel_dep(name = \"bazel_skylib\", version = \"%s\")\n", skylib_version);
        fprintf(ostream,
                "bazel_dep(name = \"rules_ocaml\", version = \"%s\")\n", rules_ocaml_version);

        fprintf(ostream,
                "bazel_dep(name = \"stublibs\", version = \"%s\")\n",
                default_version);
    } else {
        fprintf(ostream,
                "bazel_dep(name = \"rules_ocaml\", version = \"%s\")\n", rules_ocaml_version);
        fprintf(ostream,
                "bazel_dep(name = \"ocamlsdk\", version = \"%s\")\n", "0.0.0");
        fprintf(ostream,
                "bazel_dep(name = \"bazel_skylib\", version = \"%s\")\n", skylib_version);
    }

    fprintf(ostream, "\n");
    /* } */
    fclose(ostream);
    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET " wrote %s\n", utstring_body(reg_file));
}

/**
   emit:
       <reg>/modules/<module>/metadata.json
       <reg>/modules/<module>/<version>/MODULE.bazel
       <reg>/modules/<module>/<version>/source.json
       <reg>/modules/<module>/<version>/patches ???
 */
EXPORT void emit_registry_record(UT_string *registry,
                                 char *compiler_version,
                                 struct obzl_meta_package *pkg,
                                 struct obzl_meta_package *pkgs,
                                 char *obazl_pfx)
{
    TRACE_ENTRY;
    if (pkg) {
        LOG_DEBUG(0, "%s", pkg->name);
    }
    char *pkg_name;
    char *module_name;
    char version[256];
    findlib_version_t *semv;
    if (pkg) {
        pkg_name = pkg->name;
        module_name = pkg->module_name;
        semv = findlib_pkg_version(pkg);
        sprintf(version, "%d.%d.%d",
                semv->major, semv->minor, semv->patch);
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              pkg_name,
                              module_name,
                              version); //, semv->major);
    } else {
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "ocamlsdk", "ocamlsdk", "0.0.0");
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "stublibs", "stublibs", "0.0.0");
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "compiler-libs",
                              "compiler-libs",
                              "0.0.0");
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "dynlink",
                              "dynlink",
                              "0.0.0");
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "str", "str", "0.0.0");
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "threads", "threads", "0.0.0");
        _emit_registry_record(registry,
                              compiler_version,
                              pkg, pkgs,
                              obazl_pfx,
                              "unix", "unix", "0.0.0");
    }
    TRACE_EXIT;
}

void _emit_registry_record(UT_string *registry,
                           char *compiler_version,
                           struct obzl_meta_package *pkg,
                           struct obzl_meta_package *pkgs,
                           //WARN: module name is
                           // pkg_name, downcased
                           char *obazl_pfx,
                           char *pkg_name,
                           char *module_name,
                           char *version)
{
    TRACE_ENTRY;
    (void)compiler_version;
    /* UT_string *tmp; */
    /* utstring_new(tmp); */
    /* utstring_printf(tmp, "%s/modules/opam.%s", */
    /*                 utstring_body(registry), */
    /*                 module_name); */
    /* mkdir_r(utstring_body(tmp)); */

    UT_string *reg_dir;
    utstring_new(reg_dir);
    utstring_printf(reg_dir,
                    "%s/modules/opam.%s",
                    utstring_body(registry),
                    module_name);
                    /* pkg_name); */
                    /* default_version); */
                    /* (char*)version); */
    mkdir_r(utstring_body(reg_dir));
    /* log_debug("regdir: %s", utstring_body(reg_dir)); */

    // modules/$MODULE/metadata.json
    /* UT_string *metadata_json_file; */
    UT_string *bazel_file;
    utstring_new(bazel_file);
    utstring_printf(bazel_file,
                    "%s/metadata.json",
                    utstring_body(reg_dir));
    /* if (verbose) */
        /* log_info("metadata.json: %s", */
        /*          utstring_body(bazel_file)); */

    //FIXME: from opam file: maintainer(s), homepage

    char *metadata_json_template = ""
        "{\n"
        "    \"homepage\": \"\",\n"
        "    \"maintainers\": [],\n"
        "    \"versions\": [\"%s\"],\n"
        "    \"yanked_versions\": {}\n"
        "}\n";
    // optional?  "repository": ["github:obazl/semverc"]

    UT_string *metadata_json;
    utstring_new(metadata_json);
    utstring_printf(metadata_json,
                    metadata_json_template,
                    version);
    /* if (verbose) */
        /* log_info("metadata_json:\n%s", */
        /*          utstring_body(metadata_json)); */

    FILE *metadata_json_fd
        = fopen(utstring_body(bazel_file), "w");
    fprintf(metadata_json_fd,
            "%s", utstring_body(metadata_json));
    fclose (metadata_json_fd);
    if (verbosity > log_writes) {
        fprintf(INFOFD, GRN "INFO" CRESET " wrote %s\n", utstring_body(bazel_file));
        /* fflush(NULL); */
    }

    utstring_free(metadata_json);

    // modules/$MODULE/$VERSION/[MODULE.bazel, source.json]
    utstring_printf(reg_dir, "/%s", default_version); //version);
    mkdir_r(utstring_body(reg_dir));
    /* log_debug("regdir: %s", utstring_body(reg_dir)); */

    /* FIXME: just copy the MODULE.bazel file from lib */

    UT_string *reg_file;
    utstring_new(reg_file);
    utstring_printf(reg_file,
                    "%s/MODULE.bazel",
                    utstring_body(reg_dir));
    /* log_info("reg MODULE.bazel: %s", */
    /*          utstring_body(reg_file)); */

    /* if ( (strncmp("ocaml", pkg_name, 6) == 0) */
    /*      || (strncmp("stublibs", pkg_name, 8) == 0)) { */
    if (pkg == NULL) {
        // emit lib/ocaml and lib/stublibs
        _emit_reg_rec(reg_file, pkg_name);
    } else {
        emit_module_file(reg_file, obazl_pfx, pkg, pkgs);
    }
    // JUST FOR DEBUGGING:
#if defined(PROFILE_dev)
    if (pkg) {
        if (pkg->metafile) {
            utstring_new(reg_file);
            utstring_printf(reg_file,
                            "%s/META",
                            utstring_body(reg_dir));
            /* log_info("reg META: %s", */
            /*          utstring_body(reg_file)); */

            copy_buildfile(pkg->metafile, reg_file);
        }
    }
#endif

    utstring_renew(reg_file);
    utstring_printf(reg_file,
                    "%s/source.json",
                    utstring_body(reg_dir));
    /* log_info("reg source.json : %s", */
    /*          utstring_body(reg_file)); */

    char *source_json_template = ""
        "{\n"
        "    \"type\": \"local_path\",\n"
        "    \"path\": \"opam.%s\"\n"
        "}\n";

    UT_string *source_json;
    utstring_new(source_json);
    utstring_printf(source_json,
                    source_json_template,
                    pkg_name);
                    /* pkg_name); */
    /* if (verbose) { */
    /*     log_info("source_json:\n%s", */
    /*              utstring_body(source_json)); */
    /*     log_info("regfile: %s", utstring_body(reg_file)); */
    /* } */
    FILE *source_json_fd
        = fopen(utstring_body(reg_file), "w");
    fprintf(source_json_fd,
            "%s", utstring_body(source_json));
    fclose (source_json_fd);
    if (verbosity > log_writes) {
        fprintf(INFOFD, GRN "INFO" CRESET " wrote %s\n", utstring_body(reg_file));
    }

    utstring_free(source_json);

    utstring_free(reg_file);
    utstring_free(bazel_file);

    /* _emit_registry_record_alias(registry, */
    /*                             compiler_version, */
    /*                             pkg, pkgs, */
    /*                             obazl_pfx, */
    /*                             pkg_name, */
    /*                             module_name, */
    /*                             version); //, semv->major); */
    TRACE_EXIT;
}

/* void _emit_registry_record_alias(UT_string *registry, */
/*                                  char *compiler_version, */
/*                                  struct obzl_meta_package *pkg, */
/*                                  struct obzl_meta_package *pkgs, */
/*                                  //WARN: module name is */
/*                                  // pkg_name, downcased */
/*                                  char *obazl_pfx, */
/*                                  char *pkg_name, */
/*                                  char *module_name, */
/*                                  char *version) */
/* { */
/*     TRACE_ENTRY; */
/*     (void)compiler_version; */
/*     /\* UT_string *tmp; *\/ */
/*     /\* utstring_new(tmp); *\/ */
/*     /\* utstring_printf(tmp, "%s/modules/%s", *\/ */
/*     /\*                 utstring_body(registry), *\/ */
/*     /\*                 module_name); *\/ */
/*     /\* mkdir_r(utstring_body(tmp)); *\/ */

/*     UT_string *reg_dir; */
/*     utstring_new(reg_dir); */
/*     utstring_printf(reg_dir, */
/*                     "%s/modules/%s", */
/*                     utstring_body(registry), */
/*                     module_name); */
/*                     /\* pkg_name); *\/ */
/*                     /\* default_version); *\/ */
/*                     /\* (char*)version); *\/ */
/*     mkdir_r(utstring_body(reg_dir)); */
/*     /\* log_debug("regdir: %s", utstring_body(reg_dir)); *\/ */

/*     // modules/$MODULE/metadata.json */
/*     /\* UT_string *metadata_json_file; *\/ */
/*     UT_string *bazel_file; */
/*     utstring_new(bazel_file); */
/*     utstring_printf(bazel_file, */
/*                     "%s/metadata.json", */
/*                     utstring_body(reg_dir)); */
/*     /\* if (verbose) *\/ */
/*         /\* log_info("metadata.json: %s", *\/ */
/*         /\*          utstring_body(bazel_file)); *\/ */

/*     //FIXME: from opam file: maintainer(s), homepage */

/*     char *metadata_json_template = "" */
/*         "{\n" */
/*         "    \"homepage\": \"\",\n" */
/*         "    \"maintainers\": [],\n" */
/*         "    \"versions\": [\"%s\"],\n" */
/*         "    \"yanked_versions\": {}\n" */
/*         "}\n"; */
/*     // optional?  "repository": ["github:obazl/semverc"] */

/*     UT_string *metadata_json; */
/*     utstring_new(metadata_json); */
/*     utstring_printf(metadata_json, */
/*                     metadata_json_template, */
/*                     version); */
/*     /\* if (verbose) *\/ */
/*         /\* log_info("metadata_json:\n%s", *\/ */
/*         /\*          utstring_body(metadata_json)); *\/ */

/*     FILE *metadata_json_fd */
/*         = fopen(utstring_body(bazel_file), "w"); */
/*     fprintf(metadata_json_fd, */
/*             "%s", utstring_body(metadata_json)); */
/*     fclose (metadata_json_fd); */
/*     if (verbosity > log_writes) { */
/*         fprintf(INFOFD, GRN "INFO" CRESET " wrote %s\n", utstring_body(bazel_file)); */
/*         /\* fflush(NULL); *\/ */
/*     } */

/*     utstring_free(metadata_json); */

/*     // modules/$MODULE/$VERSION/[MODULE.bazel, source.json] */
/*     utstring_printf(reg_dir, "/%s", default_version); //version); */
/*     mkdir_r(utstring_body(reg_dir)); */
/*     /\* log_debug("regdir: %s", utstring_body(reg_dir)); *\/ */

/*     /\* FIXME: just copy the MODULE.bazel file from lib *\/ */

/*     UT_string *reg_file; */
/*     utstring_new(reg_file); */
/*     utstring_printf(reg_file, */
/*                     "%s/MODULE.bazel", */
/*                     utstring_body(reg_dir)); */
/*     /\* log_info("reg MODULE.bazel: %s", *\/ */
/*     /\*          utstring_body(reg_file)); *\/ */

/*     /\* if ( (strncmp("ocaml", pkg_name, 6) == 0) *\/ */
/*     /\*      || (strncmp("stublibs", pkg_name, 8) == 0)) { *\/ */
/*     if (pkg == NULL) { */
/*         // emit lib/ocaml and lib/stublibs */
/*         _emit_reg_rec(reg_file, pkg_name); */
/*     } else { */
/*         emit_module_file(reg_file, obazl_pfx, pkg, pkgs); */
/*    } */
/*     // JUST FOR DEBUGGING: */
/* #if defined(PROFILE_dev) */
/*     if (pkg) { */
/*         if (pkg->metafile) { */
/*             utstring_new(reg_file); */
/*             utstring_printf(reg_file, */
/*                             "%s/META", */
/*                             utstring_body(reg_dir)); */
/*             /\* log_info("reg META: %s", *\/ */
/*             /\*          utstring_body(reg_file)); *\/ */

/*             copy_buildfile(pkg->metafile, reg_file); */
/*         } */
/*     } */
/* #endif */

/*     utstring_renew(reg_file); */
/*     utstring_printf(reg_file, */
/*                     "%s/source.json", */
/*                     utstring_body(reg_dir)); */
/*     /\* log_info("reg source.json : %s", *\/ */
/*     /\*          utstring_body(reg_file)); *\/ */

/*     char *source_json_template = "" */
/*         "{\n" */
/*         "    \"type\": \"local_path\",\n" */
/*         "    \"path\": \"%s\"\n" */
/*         "}\n"; */

/*     UT_string *source_json; */
/*     utstring_new(source_json); */
/*     utstring_printf(source_json, */
/*                     source_json_template, */
/*                     pkg_name); */
/*                     /\* pkg_name); *\/ */
/*     /\* if (verbose) { *\/ */
/*     /\*     log_info("source_json:\n%s", *\/ */
/*     /\*              utstring_body(source_json)); *\/ */
/*     /\*     log_info("regfile: %s", utstring_body(reg_file)); *\/ */
/*     /\* } *\/ */
/*     FILE *source_json_fd */
/*         = fopen(utstring_body(reg_file), "w"); */
/*     fprintf(source_json_fd, */
/*             "%s", utstring_body(source_json)); */
/*     fclose (source_json_fd); */
/*     if (verbosity > log_writes) { */
/*         fprintf(INFOFD, GRN "INFO" CRESET " wrote %s\n", utstring_body(reg_file)); */
/*     } */

/*     utstring_free(source_json); */

/*     utstring_free(reg_file); */
/*     utstring_free(bazel_file); */
/*     TRACE_EXIT; */
/* } */

/* ************************************************ */
/*
  derives registry path, writes bazel_registry.json
*/
UT_string *config_bzlmod_registry(char *switch_name,
                                  UT_string *coswitch_root,
                                  bool bazel_env)
{
    TRACE_ENTRY;
    UT_string *obazl_registry_home;
    utstring_new(obazl_registry_home);
    if (bazel_env) {
        //in-bazel:
        //  shared: .local/share/obazl/registry
        //  local:  .config/obazl/registry
        if (xdg_install) {
            utstring_printf(obazl_registry_home,
                            "%s/registry/%s",
                            utstring_body(coswitch_root),
                            switch_name);
        } else {
            // .opam install
            utstring_printf(obazl_registry_home,
                            "%s",
                            utstring_body(coswitch_root));
        }
    } else {
        //in-opam:  <switch-pfx>/share/obazl
        if (xdg_install) {
            utstring_printf(obazl_registry_home,
                            "%s/registry/%s",
                            utstring_body(coswitch_root),
                            switch_name);
        } else {
            // .opam install
            utstring_printf(obazl_registry_home,
                            "%s",
                            utstring_body(coswitch_root));
        }
    }
    mkdir_r(utstring_body(obazl_registry_home));

    // write: bazel_registry.json
    // also MODULE.bazel, WORKSPACE???

    UT_string *module_base_path;
    utstring_new(module_base_path);
    if (bazel_env) {
        //shared: .local/share/obazl/opam/<switch-name>/lib
        //local:  .config/obazl/opam/lib
        if (xdg_install) {
            utstring_printf(module_base_path,
                            "%s/opam/%s/lib",
                            utstring_body(coswitch_root),
                            switch_name);
        } else {
            // .opam install
            utstring_printf(module_base_path, "lib");
        }
    } else {
        if (xdg_install) {
            utstring_printf(module_base_path,
                            "%s/opam/%s/lib",
                            utstring_body(coswitch_root),
                            switch_name);
        } else {
            // .opam install
            utstring_printf(module_base_path, "lib");
        }
    }
    if (verbosity > 0)
        log_info("bazel_registry.json module_base_path: %s",
                 utstring_body(module_base_path));

    char *bazel_registry_template = ""
        "{\n"
        "    \"mirrors\": [],\n"
        "    \"module_base_path\": \"%s\"\n"
        "}\n";

    UT_string *bazel_registry_json;
    utstring_new(bazel_registry_json);
    utstring_printf(bazel_registry_json,
                    bazel_registry_template,
                    utstring_body(module_base_path));
    utstring_free(module_base_path);

    if (verbosity > 2)
        log_info("bazel_registry_json:\n%s",
                 utstring_body(bazel_registry_json));

    UT_string *obazl_registry_json_file;
    utstring_new(obazl_registry_json_file);
    utstring_printf(obazl_registry_json_file,
                    "%s/bazel_registry.json",
                    utstring_body(obazl_registry_home));
    if (verbosity > 2)
        log_info("bazel_registry.json:\n%s",
                 utstring_body(obazl_registry_json_file));

    FILE *bazel_registry_json_fd
        = fopen(utstring_body(obazl_registry_json_file), "w");
    fprintf(bazel_registry_json_fd,
            "%s", utstring_body(bazel_registry_json));
    fclose (bazel_registry_json_fd);

    TRACE_EXIT;
    return obazl_registry_home;
}

void write_registry_directive(char *registry)
                               /* char *switch_name) */
{
    TRACE_ENTRY;

    UT_string *content;
    utstring_new(content);
    utstring_printf(content,
                    "common --registry=file://%s", // /%s",
                    registry); //, switch_name);
    /* log_debug("CONTENT: %s", utstring_body(content)); */

    UT_string *fname;
    utstring_new(fname);
    char *wsd = getenv("BUILD_WORKSPACE_DIRECTORY");
    utstring_printf(fname,
                    "%s/.config",
                    wsd);
    mkdir_r(utstring_body(fname));
    utstring_printf(fname, "/coswitch_registry.bazelrc");
    /* log_debug("bazelrc: %s", utstring_body(fname)); */

    FILE *ostream;
    errno = 0;
    ostream = fopen(utstring_body(fname), "w");
    if (ostream == NULL) {
        log_error("Fileopen %s error %s",
                  utstring_body(fname),
                  strerror(errno));
        return;
    }
    fprintf(ostream, "%s", utstring_body(content));
    fclose(ostream);

    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET
                " WROTE: %s\n", utstring_body(fname));

    utstring_free(fname);
    utstring_free(content);
    TRACE_EXIT;
}
