#include <stdlib.h>

#include "liblogc.h"
#include "librunfiles.h"
#include "utarray.h"
#include "utstring.h"
#include "unity.h"
#include "dune_pkg_test.h"

char *errmsg = "";

char *data, *actual, *expected;

#define DEBUG_LEVEL debug_dune_test
extern int  DEBUG_LEVEL;
#define TRACE_FLAG trace_dune_test
extern bool TRACE_FLAG;

#define CHECK_RESULT(expected, actual) \
    if (actual == NULL) {                            \
        TEST_FAIL_MESSAGE("Lexical error");          \
    } else {                                         \
        TEST_ASSERT_EQUAL_STRING(expected, actual);  \
        free(actual);                                \
    }

void setUp(void) {
    if (fflush(stdout) == EOF) {
        /* Handle error */
    }
}

void tearDown(void) {
    if (fflush(stdout) == EOF) {
        /* Handle error */
    }
}


void bin(void) {
    char *f = rf_rlocation(BAZEL_CURRENT_REPOSITORY
                           "test/data/menhir.dune-package");
    log_debug("test file %s", f);
    dune_package_open(f);
    expected = "";
    UT_array *actual
        = dune_package_files_fld("bin");
    TEST_ASSERT_EQUAL_INT(1, utarray_len(actual));
    char **p = utarray_eltptr(actual, 0);
    TEST_ASSERT_EQUAL_STRING("menhir", *p);
    free(actual);
    dune_package_close();
}

void stublibs(void) {
    char *f = rf_rlocation(BAZEL_CURRENT_REPOSITORY
                           "test/data/base.dune-package");
    //"test/data/ppx_expect.dune-package");
    log_debug("test file %s", f);
    dune_package_open(f);
    expected = "";
    UT_array *actual = dune_package_files_fld("stublibs");
    TEST_ASSERT_EQUAL_INT(2, utarray_len(actual));
    char **p = utarray_eltptr(actual, 0);
    TEST_ASSERT_EQUAL_STRING("dllbase_internalhash_types_stubs.so", *p);
    p = utarray_eltptr(actual, 1);
    TEST_ASSERT_EQUAL_STRING("dllbase_stubs.so", *p);
    utarray_free(actual);
    dune_package_close();
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    initialize(argc, argv, "dune_pkg");
    rf_init(argv[0]);
    LOG_DEBUG(0, "beginning dune_pkg test", "");

    UNITY_BEGIN();

    RUN_TEST(bin);
    /* RUN_TEST(stublibs); */

    int rc = UNITY_END();
    if (fflush(stdout) == EOF) {
        /* Handle error */
    }
    return rc;
}
