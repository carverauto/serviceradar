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
#include <sys/stat.h>
#include <unistd.h>

#include "gopt.h"
#include "liblogc.h"
#include "utarray.h"
#include "uthash.h"
#include "utstring.h"

#include "main.h"

bool bazel_env;

extern bool xdg_install;
extern char *switch_name;

#define DEBUG_LEVEL coswitch_debug
extern int  DEBUG_LEVEL;
#define TRACE_FLAG coswitch_trace
extern bool TRACE_FLAG;
extern bool trace_findlibc;
extern int  debug_findlibc;
extern bool opamc_trace;
extern int  opamc_debug;
extern bool xdgc_trace;
extern int  xdgc_debug;

#define S7_DEBUG_LEVEL libs7_debug
extern int  libs7_debug;
extern bool libs7_trace;

bool quiet;
bool verbose;
int  verbosity;

extern char *rules_ocaml_version;
extern bool enable_jsoo;

enum OPTS {
    OPT_PKG = 0,
    OPT_SWITCH,
    OPT_RULES_OCAML,
    FLAG_JSOO,
    FLAG_XDG_INSTALL,
    FLAG_CLEAN,
    FLAG_SHOW_CONFIG,
#if defined(PROFILE_fastbuild)
    OPT_DEBUG_LIBS7,
    FLAG_TRACE_LIBS7,
    FLAG_DEBUG,
    FLAG_TRACE,
    OPT_DEBUG_FINDLIBC,
    FLAG_TRACE_FINDLIBC,
    OPT_DEBUG_OPAMC,
    FLAG_TRACE_OPAMC,
#endif
    FLAG_VERBOSE,
    FLAG_VERSION,
    FLAG_FINDLIBC_VERSION,
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

    printf("\t-x, --xdg\t\t\tInstall coswitch to $XDG_DATA_HOME/obazl. Default: install to $OPAM_SWITCH_PREFIX/share/obazl\n");

    /* printf("Flags\n"); */
    /* printf("\t-j, --jsoo\t\t\tImport Js_of_ocaml resources.\n"); */
    /* printf("\t-c, --clean\t\t\tClean coswitch and reset to uninitialized state. (temporarily disabled)\n"); */

    printf("\t-q, --quiet\t\t\tSuppress all stdout msgs.\n");
    printf("\t-v, --verbose\t\t\tEnable verbosity. Repeatable.\n");
    printf("\t    --version\t\t\tPrint version identifier.\n");

#if defined(PROFILE_fastbuild)
    printf("\t-d, --debug\t\t\tEnable debug flags. Repeatable.\n");
    printf("\t-t, --trace\t\t\tEnable all trace flags (debug only).\n");
#endif

    printf("\t    --debug-libs7\t\tEnable libs7 debug flags. Repeatable.\n");
    printf("\t    --trace-libs7\t\tEnable libs7 trace flags.\n");

}

static struct option options[] = {
    /* 0 */
    [OPT_PKG] = {.long_name="pkg",.short_name='p',
                 .flags=GOPT_ARGUMENT_REQUIRED},
    [OPT_SWITCH] = {.long_name="switch",.short_name='s',
                 .flags=GOPT_ARGUMENT_REQUIRED},
    [OPT_RULES_OCAML] = {.long_name="rules_ocaml",
                         .flags=GOPT_ARGUMENT_REQUIRED},
    [FLAG_XDG_INSTALL] = {.long_name="xdg", .short_name='x',
                          .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_JSOO] = {.long_name="jsoo", .short_name='j',
                   .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_CLEAN] = {.long_name="clean",.short_name='c',
                    .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_SHOW_CONFIG] = {.long_name="show-config",
                          .flags=GOPT_ARGUMENT_FORBIDDEN},

#if defined(PROFILE_fastbuild)
    [OPT_DEBUG_LIBS7] = {.long_name="debug-libs7",
                           .flags=GOPT_ARGUMENT_REQUIRED},
    [FLAG_TRACE_LIBS7] = {.long_name="trace-libs7",
                             .flags=GOPT_ARGUMENT_FORBIDDEN},

    [FLAG_DEBUG] = {.long_name="debug",.short_name='d',
                    .flags=GOPT_ARGUMENT_FORBIDDEN | GOPT_REPEATABLE},
    [FLAG_TRACE] = {.long_name="trace",.short_name='t',
                    .flags=GOPT_ARGUMENT_FORBIDDEN},

    [OPT_DEBUG_FINDLIBC] = {.long_name="debug-findlibc",
                           .flags=GOPT_ARGUMENT_REQUIRED},
    [FLAG_TRACE_FINDLIBC] = {.long_name="trace-findlibc",
                             .flags=GOPT_ARGUMENT_FORBIDDEN},

    [OPT_DEBUG_OPAMC] = {.long_name="debug-opamc",
                           .flags=GOPT_ARGUMENT_REQUIRED},
    [FLAG_TRACE_OPAMC] = {.long_name="trace",
                          .flags=GOPT_ARGUMENT_FORBIDDEN},
#endif

    [FLAG_VERBOSE] = {.long_name="verbose",.short_name='v',
                      .flags=GOPT_ARGUMENT_FORBIDDEN | GOPT_REPEATABLE},
    [FLAG_VERSION] = {.long_name="version",
                      .flags=GOPT_ARGUMENT_FORBIDDEN },
    [FLAG_FINDLIBC_VERSION] = {.long_name="findlibc-version",
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
        verbose = true;
        verbosity = options[FLAG_VERBOSE].count;
    }

#if defined(PROFILE_fastbuild)
    if (options[OPT_DEBUG_LIBS7].count) {
        errno = 0;
        long tmp = strtol(options[OPT_DEBUG_LIBS7].argument,
                          NULL, 10);
        if (errno) {
            log_error( "--debug-libs7 must be an int.");
            exit(EXIT_FAILURE);
        } else {
            libs7_debug = (int)tmp;
        }
    }
#endif

#if defined(PROFILE_fastbuild)
    if (options[FLAG_TRACE_LIBS7].count) {
        libs7_trace = true;
    }

    if (options[FLAG_DEBUG].count) {
        coswitch_debug = options[FLAG_DEBUG].count;
    }
    if (options[FLAG_TRACE].count) {
        coswitch_trace = true;
    }

    if (options[OPT_DEBUG_FINDLIBC].count) {
        errno = 0;
        long tmp = strtol(options[OPT_DEBUG_FINDLIBC].argument,
                          NULL, 10);
        if (errno) {
            log_error( "--debug-findlibc must be an int.");
            exit(EXIT_FAILURE);
        } else {
            debug_findlibc = (int)tmp;
        }
    }
    if (options[FLAG_TRACE_FINDLIBC].count) {
        trace_findlibc = true;
    }

    if (options[OPT_DEBUG_OPAMC].count) {
        errno = 0;
        long tmp = strtol(options[OPT_DEBUG_OPAMC].argument,
                          NULL, 10);
        if (errno) {
            /* fprintf(stderr, "--findlib-debug must be an int."); */
            log_error( "--debug-opamc must be an int.");
            exit(EXIT_FAILURE);
        } else {
            opamc_debug = (int)tmp;
        }
    }
    if (options[FLAG_TRACE_OPAMC].count) {
        opamc_trace = true;
    }
#endif
    if (options[FLAG_JSOO].count) {
        enable_jsoo = true;
    }

    if (options[FLAG_XDG_INSTALL].count) {
        xdg_install = true;
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
        /* fprintf(stdout, "%s\n", coswitch_version); */
        exit(EXIT_SUCCESS);
    }
    if (options[FLAG_FINDLIBC_VERSION].count) {
        /* fprintf(stdout, "findlibc %s\n", findlibc_version); */
        exit(EXIT_SUCCESS);
    }
    /* dump env vars: */
    /* log_debug("ENV"); */
    /* int i = 0; */
    /* while(environ[i]) { */
    /*     log_info("%s", environ[i++]); */
    /* } */

    if (options[OPT_SWITCH].count) {
        switch_name = options[OPT_SWITCH].argument;
    }

    if (options[OPT_RULES_OCAML].count) {
        rules_ocaml_version = options[OPT_RULES_OCAML].argument;
    }

    if (options[FLAG_QUIET].count) {
        quiet = true;
    }

    coswitch_main(argv[0]);

#if defined(TRACING)
    log_debug("exiting coswitch:new");
#endif
    /* dump_nodes(result); */
}
