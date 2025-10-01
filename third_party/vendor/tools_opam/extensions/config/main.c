//FIXME: support -j (--jsoo-enable) flag

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>

#if INTERFACE
#ifdef __linux__
#include <linux/limits.h>
#else
#include <limits.h>
#endif
#endif
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "gopt.h"
#include "liblogc.h"
#include "librunfiles.h"
#include "utstring.h"

#include "main.h"

bool bazel_env;

extern char *switch_name;

#define DEBUG_LEVEL debug_tools_opam
extern int  DEBUG_LEVEL;
#define TRACE_FLAG trace_tools_opam
extern bool TRACE_FLAG;

extern int  debug_findlibc;
extern bool trace_findlibc;

extern int  coswitch_debug;
extern bool coswitch_trace;

extern bool quiet;
bool verbose;
extern int  verbosity;

enum OPTS {
    OPT_PKG = 0,
    OPT_PKG_PFX,
    OPT_OCAML_VERSION,
    OPT_SWITCH_PFX,
    FLAG_CLEAN,
    FLAG_DEBUG,
    FLAG_TRACE,
    FLAG_DEBUG_FINDLIBC,
    FLAG_TRACE_FINDLIBC,
    FLAG_VERBOSE,
    FLAG_VERSION,
    FLAG_QUIET,
    FLAG_HELP,
    LAST
};

void _print_usage(void) {
    if (bazel_env) {
        printf("Usage:\t$ bazel run @coswitch//new [args]\n");
    } else {
        printf("Usage:\t$ coswitch [args]\n");
    }

    printf("\t-s, --switch <name>\t\tOPAM switch to use. Default: current switch\n");

    /* printf("Flags\n"); */
    /* printf("\t-j, --jsoo\t\t\tImport Js_of_ocaml resources.\n"); */
    /* printf("\t-c, --clean\t\t\tClean coswitch and reset to uninitialized state. (temporarily disabled)\n"); */

    printf("\t-q, --quiet\t\t\tSuppress all stdout msgs.\n");
    printf("\t-v, --verbose\t\t\tEnable verbosity. Repeatable.\n");
    printf("\t    --version\t\t\tPrint version identifier.\n");

    printf("\t-d, --debug\t\t\tEnable debug flags. Repeatable.\n");
    printf("\t-t, --trace\t\t\tEnable all trace flags (debug only).\n");
}

static struct option options[] = {
    /* 0 */
    [OPT_PKG] = {.long_name="pkg",.short_name='p',
                 .flags=GOPT_ARGUMENT_REQUIRED},
    [OPT_PKG_PFX] = {.long_name="pkg-pfx",
        .flags=GOPT_ARGUMENT_REQUIRED},
    [OPT_OCAML_VERSION] = {.long_name="ocaml-version",
                           .flags=GOPT_ARGUMENT_REQUIRED},
    [OPT_SWITCH_PFX]    = {.long_name="switch-pfx",
        .flags=GOPT_ARGUMENT_REQUIRED},
    [FLAG_CLEAN] = {.long_name="clean",.short_name='c',
                    .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_DEBUG] = {.long_name="debug",.short_name='d',
                    .flags=GOPT_ARGUMENT_FORBIDDEN | GOPT_REPEATABLE},
    [FLAG_DEBUG_FINDLIBC] = {
        .long_name="debug-findlibc",
        .flags=GOPT_ARGUMENT_FORBIDDEN | GOPT_REPEATABLE},
    [FLAG_TRACE] = {.long_name="trace",.short_name='t',
                    .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_TRACE_FINDLIBC] = {
        .long_name="trace-findlibc",
        .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_VERBOSE] = {.long_name="verbose",.short_name='v',
                      .flags=GOPT_ARGUMENT_FORBIDDEN | GOPT_REPEATABLE},
    [FLAG_VERSION] = {.long_name="version",
                      .flags=GOPT_ARGUMENT_FORBIDDEN },
    [FLAG_QUIET] = {.long_name="quiet",.short_name='q',
                    .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_HELP] = {.long_name="help",.short_name='h',
                   .flags=GOPT_ARGUMENT_FORBIDDEN},
    [LAST] = {.flags = GOPT_LAST}
};

void _set_options(struct option options[])
{
    if (options[FLAG_HELP].count) {
        _print_usage();
        exit(EXIT_SUCCESS);
    }

    if (options[FLAG_VERBOSE].count) {
        /* printf("verbose ct: %d\n", options[FLAG_VERBOSE].count); */
        verbose = true;
        verbosity = options[FLAG_VERBOSE].count;
    }

    if (options[FLAG_DEBUG].count) {
        debug_tools_opam = 3; //options[FLAG_DEBUG].count;
        coswitch_debug = 3; //debug_tools_opam;
    }
    if (options[FLAG_TRACE].count) {
        trace_tools_opam = true;
        coswitch_trace = true; //trace_tools_opam;
    }
    if (options[FLAG_DEBUG_FINDLIBC].count) {
        debug_findlibc = 3; //options[FLAG_DEBUG].count;
    }
    if (options[FLAG_TRACE_FINDLIBC].count) {
        trace_findlibc = true;
    }

}

extern char **environ;

int main(int argc, char *argv[])
{
    argc = gopt(argv, options);
    (void)argc;

    gopt_errors (argv[0], options);

    _set_options(options);

    if (options[FLAG_VERSION].count) {
        /* fprintf(stdout, "%s\n", config_pkg_version); */
        exit(EXIT_SUCCESS);
    }
    /* dump env vars: */
    /* log_debug("ENV"); */
    /* int i = 0; */
    /* while(environ[i]) { */
    /*     log_info("%s", environ[i++]); */
    /* } */

    if (options[FLAG_QUIET].count) {
        quiet = true;
    }

    if (!options[OPT_PKG].count) {
        log_error("-p <pkg> or --pkg <pkg> required");
        exit(EXIT_FAILURE);
    }
    /* if (!options[OPT_PKG_PFX].count) { */
    /*     log_error("--pkg-pfx <str> required"); */
    /*     exit(EXIT_FAILURE); */
    /* } */
    /* if (!options[OPT_OCAML_VERSION].count) { */
    /*     log_error("--ocaml-version <v> required"); */
    /*     exit(EXIT_FAILURE); */
    /* } */
    if (!options[OPT_SWITCH_PFX].count) {
        log_error("--switch-pfx <path> required");
        exit(EXIT_FAILURE);
    }
    /* if (!options[OPT_SWITCH_LIB].count) { */
    /*     log_error("--switch-lib <path> required"); */
    /*     exit(EXIT_FAILURE); */
    /* } */

    rf_init(argv[0]);

    char *cwd = getcwd(NULL, 0);
    (void)cwd;
    LOG_DEBUG(0, "cwd: '%s'", cwd);
    /* size_t length; */
    /* cwk_path_get_dirname(cwd, &length); */
    /* log_debug("cwd dirname is: '%.*s'", (int)length, cwd); */
    /* UT_string *dir; */
    /* utstring_new(dir); */
    /* utstring_printf(dir, "%.*stools_opam+", */
    /*                 (int)length, cwd); */
    /* log_debug("runfiles: %s", utstring_body(dir)); */

    /* printf("BAZEL_CURRENT_REPOSITORY: %s\n", BAZEL_CURRENT_REPOSITORY); */
    /* printf("rf_root: %s\n", rf_root()); */

    /* char *f = BAZEL_CURRENT_REPOSITORY */
    /*     "lib/templates/ocamlsdk/bigarray.BUILD"; */
    /* LOG_DEBUG(0, "searching for: %s", f); */
    /* char *rf = rf_rlocation(f); */
    /* int rc = access(rf, F_OK); */
    /* if (rc == 0) { */
    /*     LOG_DEBUG(0, "FOUND", ""); */
    /* } else { */
    /*     LOG_DEBUG(0, "NOT FOUND", ""); */
    /* } */
    /* exit(0); */

    opam_pkg_handler(options[OPT_SWITCH_PFX].argument,
                     options[OPT_OCAML_VERSION].argument,
                     options[OPT_PKG].argument,
                     options[OPT_PKG_PFX].count
                     ? options[OPT_PKG_PFX].argument
                     : "");
                     /* options[OPT_SWITCH_LIB].argument, */
    LOG_INFO(0, "cwd: %s", getcwd(NULL, 0));

    /* FILE *ostream = fopen(utstring_body(dst_file), "w"); */
    /* if (ostream == NULL) { */
    /*     log_error("%s", strerror(errno)); */
    /*     perror(utstring_body(dst_file)); */
    /*     exit(EXIT_FAILURE); */
    /* } */
    /* fprintf(ostream, "## generated file - DO NOT EDIT\n\n"); */


    TRACE_EXIT;
}

    /* UT_string *dst_file; */
    /* utstring_new(dst_file); */
    /* utstring_printf(dst_file, "%s/TESTMOD", */
    /*                 //options[OPT_PKG].argument */
    /*                 "."); */
    /* FILE *ostream = fopen(utstring_body(dst_file), "w"); */
    /* if (ostream == NULL) { */
    /*     log_error("%s", strerror(errno)); */
    /*     perror(utstring_body(dst_file)); */
    /*     exit(EXIT_FAILURE); */
    /* } */
    /* fprintf(ostream, "## generated file - DO NOT EDIT\n\n"); */
    /* fprintf(ostream, "module(\n"); */
    /* fprintf(ostream, "    name = \"test\", version = \"0.0.0\",\n"); */
    /* fprintf(ostream, "    compatibility_level = 0,\n"); */
    /* fprintf(ostream, "    bazel_compatibility = [\">=8.0.0\"]\n"); */
    /* fprintf(ostream, ")\n"); */
    /* fprintf(ostream, "\n"); */
    /* fclose(ostream); */

    /* fprintf(stdout, "dep01\n"); */
    /* fprintf(stdout, "dep02\n"); */
    /* fprintf(stdout, "cwd: %s\n", cwd); */

