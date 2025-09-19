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
    if (argc > 2) {
        if ((strncmp(argv[2], "-v", 2) == 0)
            && (strlen(argv[2]) == 2)) {
            verbose = true;
            skip = 2;
        }
    }
    int ct = 1; /* for terminating \0 */
    for (int i = 1; i < argc; i++) {{
        if ( i == skip) continue;
        ct += strlen(argv[i]) + 1;
    }}
    char *cmd = malloc(ct);
    int offset = 0;
    int written = 0;
    int available_space = 0;
    for (int i = 1; i < argc; i++) {{
        if (i == skip) continue;
        available_space = ct - offset;
        if (available_space <= 0) {{
            break; // Prevent buffer overflow
        }}
        written = snprintf(cmd + offset, available_space,
                           "%s ", argv[i]);
        if (written < 0 || written >= available_space) {{
            cmd[offset] = '\0'; // Ensure null termination
            break; // Stop on encoding error or not enough space
        }}
        offset += written;
    }}

    if (verbose) {
        fprintf(stdout, YEL "Build workspace root" CRESET
                "   : %s\n", getenv("BUILD_WORKSPACE_DIRECTORY"));
        fprintf(stdout, YEL "  opam bin" CRESET
                "             : %s\n", getenv("OPAMBIN"));
        fprintf(stdout, YEL "  OPAMROOT" CRESET
                "             : %s\n", getenv("OPAMROOT"));
        fprintf(stdout, YEL "  OPAMSWITCH" CRESET
                "           : %s\n", getenv("OPAMSWITCH"));
        fprintf(stdout, YEL "  OCAML_TOPLEVEL_PATH" CRESET
                "  : '%s'\n", getenv("OCAML_TOPLEVEL_PATH"));
        fprintf(stdout, YEL "  CAML_LD_LIBRARY_PATH" CRESET
                " : '%s'\n", getenv("CAML_LD_LIBRARY_PATH"));
        fprintf(stdout, YEL "  cmd" CRESET
                "                  : '%s'\n\n", cmd);
        /* exit(EXIT_SUCCESS); */
    }
    /* if (verbose) { */
    /*     fprintf(stdout, YEL "  cmd" CRESET */
    /*             "                  : '%s'\n", cmd); */
    /* } */

    char *bwsd = getenv("BUILD_WORKSPACE_DIRECTORY");

    chdir(bwsd);

    system(cmd); //argv[1]);

    free(cmd);
}
