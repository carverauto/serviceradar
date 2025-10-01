#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define YEL "\033[0;33m"
#define RED "\033[0;31m"
#define CRESET "\033[0m"

int main(int argc, char *argv[])
{
    if (argc > 2) {
        if ((strncmp(argv[2], "init", 4) == 0)
            || (strncmp(argv[2], "admin", 5) == 0)
            || (strncmp(argv[2], "repository", 10) == 0)) {
            printf("runningX\n");
            fprintf(stderr, RED "ERROR: " CRESET
            "opam operation not supported by OBazl: %s\n", argv[2]);
            return EXIT_FAILURE;
        }
    }
    fprintf(stdout, YEL "Root module" CRESET
        "  : %s\n", getenv("ROOTMODULE"));
    fprintf(stdout, YEL "  OPAMBINDIR" CRESET
        " : %s\n", getenv("OPAMBINDIR"));
    fprintf(stdout, YEL "  OPAMROOT" CRESET
        "   : %s\n", getenv("OPAMROOT"));
    fprintf(stdout, YEL "  OPAMSWITCH" CRESET
        " : %s\n", getenv("OPAMSWITCH"));
    fprintf(stdout, "\n");
    int ct = 1; /* for terminating \0 */
    for (int i = 1; i < argc; i++) {
        ct += strlen(argv[i]) + 1;
    }
    char *cmd = malloc(ct);
    int offset = 0;
    int written = 0;
    int available_space = 0;
    for (int i = 1; i < argc; i++) {
        available_space = ct - offset;
        if (available_space <= 0) {
            break; // Prevent buffer overflow
        }
        written = snprintf(cmd + offset, available_space,
                           "%s ", argv[i]);
        (void)written;
        if (written < 0 || written >= available_space) {
            cmd[offset] = '\0'; // Ensure null termination
            break; // Stop on encoding error or not enough space
        }
        offset += written;
    }
    system(cmd); //argv[1]);
    free(cmd);
}
