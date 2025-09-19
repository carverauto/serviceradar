#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define YEL "\033[0;33m"
#define RED "\033[0;31m"
#define CRESET "\033[0m"

int main(int argc, char *argv[])
{
    bool verbose = false;
    int skip = 0;
    if (argc > 1) {
        if ((strncmp(argv[1], "-v", 2) == 0)
            && (strlen(argv[1]) == 2)) {
            verbose = true;
            skip = 2;
        }
    }
    char *_dbg = getenv("OCAMLDEBUG");
    char *real_dbg = realpath(_dbg, NULL);
    char *_pgm = getenv("OBAZL_DEBUG_TGT");
    char *real_pgm = realpath(_pgm, NULL);
    int ct = strlen(real_dbg) + strlen(real_pgm) + 3;

    for (int i = 1; i < argc; i++) {
        if ( i == skip) continue;
        ct += strlen(argv[i]) + 1;
    }
    char *cmd = malloc(ct);
    int offset = 0;
    int written = 0;
    int available_space = ct;

    written = snprintf(cmd, ct, "%s %s ",
                       real_dbg, real_pgm);
    if (written < 0 || written >= available_space) {
        cmd[offset] = '\0'; // Ensure null termination
        /* ? */
        }
    offset += written;

    for (int i = 1; i < argc; i++) {
        if (i == skip) continue;
        available_space = ct - offset;
        if (available_space <= 0) {
            break; // Prevent buffer overflow
        }
        written = snprintf(cmd + offset, available_space,
                           "%s ", argv[i]);
        if (written < 0 || written >= available_space) {
            cmd[offset] = '\0'; // Ensure null termination
            break; // Stop on encoding error or not enough space
        }
        offset += written;
    }

        fprintf(stdout, YEL "Build workspace root" CRESET
                "   : %s\n", getenv("BUILD_WORKSPACE_DIRECTORY"));
        fprintf(stdout, YEL "  OCAMLDEBUG" CRESET
                "           : %s\n", real_dbg);
        fprintf(stdout, YEL "  DEBUGGING" CRESET
                "            : %s\n", real_pgm);
        fprintf(stdout, YEL "  OCAMLRUNPARAM" CRESET
                "        : %s\n", getenv("OCAMLRUNPARAM"));
    if (verbose) {
        fprintf(stdout, YEL "  OPAMROOT" CRESET
                "             : %s\n", getenv("OPAMROOT"));
        fprintf(stdout, YEL "  OPAMSWITCH" CRESET
                "           : %s\n", getenv("OPAMSWITCH"));
        /* fprintf(stdout, YEL "  PGM" CRESET */
        /*         "  : '%s'\n", getenv("PGM")); */
        fprintf(stdout, YEL "  CAML_LD_LIBRARY_PATH" CRESET
                " : '%s'\n", getenv("CAML_LD_LIBRARY_PATH"));
        fprintf(stdout, YEL "  cmd" CRESET
                "                  : '%s'\n\n", cmd);
        /* exit(EXIT_SUCCESS); */
    }
    /* printf("cwd %s\n", getcwd(NULL,0)); */

    printf("\n");

    char *bwsd = getenv("BUILD_WORKSPACE_DIRECTORY");
    int rc = chdir(bwsd);

    rc = system(cmd);
    (void)rc;

    free(cmd);
}
