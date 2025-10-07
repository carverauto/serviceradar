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
        fprintf(stderr, RED "ERROR: " CRESET
        "no arguments allowed for %s\n", argv[2]);
            return EXIT_FAILURE;
    }
    fprintf(stdout, YEL "Root module" CRESET
        "  : %s\n", getenv("ROOTMODULE"));
    fprintf(stdout, YEL "  OPAMBINDIR" CRESET
        " : %s\n", getenv("OPAMBINDIR"));
    fprintf(stdout, YEL "  OPAMROOT" CRESET
        "   : %s\n", getenv("OPAMROOT"));
    fprintf(stdout, YEL "  OPAMSWITCH" CRESET
        " : %s\n", getenv("OPAMSWITCH"));
    fprintf(stdout, YEL "INFO: " CRESET
        "Reinitializing opam installation.  ");
    fprintf(stdout, "Bazel support (network access) will be removed.\n");

    char *cmd = "opam init --reinit --bypass-checks --no --quiet ";
    fprintf(stdout, YEL "INFO: " CRESET "cmd: '%s'\n", cmd);
    fprintf(stdout, "\n");

    system(cmd);
}
