#include <stdbool.h>

bool xdg_install = false;


extern char *findlibc_version;

char *default_version = "0.0.0";
int   default_compat  = 0;
char *bazel_compat    = "8.0.0";

char *platforms_version = "0.0.10";
char *skylib_version    = "1.7.1";
char *rules_cc_version  = "0.0.17";

char *rules_ocaml_version = "5.0.0";  /* "2.1.0"; */
char *ocaml_version = "0.0.0";
char *compiler_version;

int log_writes = 1; // threshhold for logging all writes
int log_symlinks = 2;
bool enable_jsoo;

int level = 0;
int spfactor = 4;
char *sp = " ";

