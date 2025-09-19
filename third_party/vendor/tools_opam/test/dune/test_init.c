#include <libgen.h>
#include <pwd.h>
#include <stdlib.h>             /* putenv */
#include <unistd.h>             /* getcwd */
#include <sys/errno.h>
#include <sys/types.h>

#include "gopt.h"
#include "liblogc.h"
#include "unity.h"
/* #include "utarray.h" */
/* #include "utstring.h" */

#include "test_init.h"

#define DEBUG_LEVEL debug_dune_test
int DEBUG_LEVEL;
#define TRACE_FLAG trace_dune_test
bool TRACE_FLAG;

bool verbose;

void print_usage(char *test) {
    (void)test;
    /* printf("Usage:\t$ bazel test test/unit:%s [--test_arg=flag]\n", test); */
    printf("Flags (repeatable)\n");
    printf("\t-d, --debug\t\tEnable test debug flags.\n");
    printf("\t--debug-lexer\t\tEnable lexer debugging flags.\n");
    printf("\t--debug-parser\t\tEnable parser flags.\n");
    printf("\t-t, --trace\t\tEnable test tracing.\n");
    printf("\t--trace-lexer\t\tEnable lexer tracing.\n");
    printf("\t--trace-parser\t\tEnable parser tracing.\n");
    printf("\t-v, --verbose\t\tEnable verbosity.\n");
}

enum OPTS {
    FLAG_HELP,
    FLAG_DEBUG,
    FLAG_TRACE,
    FLAG_VERBOSE,
    LAST
};

struct option options[] = {
    /* 0 */
    [FLAG_DEBUG] = {.long_name="debug",.short_name='d',
                    .flags=GOPT_ARGUMENT_FORBIDDEN
                    | GOPT_REPEATABLE},
    [FLAG_TRACE] = {.long_name="trace",.short_name='t',
                    .flags=GOPT_ARGUMENT_FORBIDDEN},
    [FLAG_VERBOSE] = {.long_name="verbose",.short_name='v',
                      .flags=GOPT_ARGUMENT_FORBIDDEN | GOPT_REPEATABLE},
    [FLAG_HELP] = {.long_name="help",.short_name='h',
                   .flags=GOPT_ARGUMENT_FORBIDDEN},
    [LAST] = {.flags = GOPT_LAST}
};

void set_options(char *test, struct option options[])
{
    if (options[FLAG_HELP].count) {
        print_usage(test);
        exit(EXIT_SUCCESS);
    }
    if (options[FLAG_DEBUG].count) {
        debug_dune_test     = options[FLAG_DEBUG].count;
    }
    if (options[FLAG_TRACE].count) {
        trace_dune_test      = true;
    }
    if (options[FLAG_VERBOSE].count) {
        log_info("verbose ct: %d", options[FLAG_VERBOSE].count);
        verbose = true;
    }
}

void print_debug_env(void)
{
    log_debug("getcwd: %s", getcwd(NULL, 0));
    log_debug("getenv(PWD): %s", getenv("PWD"));

    // $HOME - not reliable, use getpwuid() instead
    log_debug("getenv(HOME): %s", getenv("HOME"));
    struct passwd* pwd = getpwuid(getuid());
    log_debug("pwd->pw_dir: %s", pwd->pw_dir);

    /* log_debug("LOCAL_REPO (macro): '%s'", LOCAL_REPO); */

    // TEST_WORKSPACE: always the root ws
    log_debug("TEST_WORKSPACE: '%s'", getenv("TEST_WORKSPACE"));

    // BAZEL_TEST: should always be true when this is compiled as cc_test
    log_debug("BAZEL_TEST: '%s'", getenv("BAZEL_TEST"));

    // BUILD_WORK* vars: null under 'bazel test'
    log_debug("BUILD_WORKSPACE_DIRECTORY: %s", getenv("BUILD_WORKSPACE_DIRECTORY"));
    log_debug("BUILD_WORKING_DIRECTORY: %s", getenv("BUILD_WORKING_DIRECTORY"));

    // TEST_SRCDIR - required for cc_test
    log_debug("TEST_SRCDIR: %s", getenv("TEST_SRCDIR"));
    log_debug("BINDIR: %s", getenv("BINDIR"));

    /* RUNFILES_MANIFEST_FILE: null on macos. */
    log_debug("RUNFILES_MANIFEST_FILE: %s", getenv("RUNFILES_MANIFEST_FILE"));

    /* RUNFILES_MANIFEST_FILE: null on macos. */
    log_debug("RUNFILES_MANIFEST_ONLY: %s", getenv("RUNFILES_MANIFEST_ONLY"));

    /* RUNFILES_DIR: set on macos for both bazel test and bazel run. */
    log_debug("RUNFILES_DIR: %s", getenv("RUNFILES_DIR"));
}

void cleanup(void)
{
    /* https://wiki.sei.cmu.edu/confluence/display/c/FIO23-C.+Do+not+exit+with+unflushed+data+in+stdout+or+stderr */
    /* Do cleanup */
    /* printf("All cleaned up!\n"); */
    if (fflush(stdout) == EOF) {
        /* Handle error */
    }
}

void initialize(int argc, char **argv, char *test_pkg)
{
    atexit(cleanup);

    if ( !getenv("BAZEL_TEST") ) {
        log_error("This test must be run in a Bazel environment: bazel test //path/to/test (or bazel run)" );
        exit(EXIT_FAILURE);
    }

    /* log_trace("WS: %s", getenv("TEST_WORKSPACE")); */
    /* log_debug("ARGV[0]: %s", argv[0]); */
    /* log_debug("CWD: %s", getcwd(NULL, 0)); */

    argc = gopt (argv, options);
    (void)argc;
    gopt_errors (argv[0], options);

    set_options(test_pkg, options);

    /* LOG_DEBUG(0, print_debug_env(), ""); */
}
