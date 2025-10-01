#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define YEL "\033[0;33m"
#define RED "\033[0;31m"
#define CRESET "\033[0m"

int main(int argc, char *argv[])
{
    if (argc > 3) {
        fprintf(stderr, RED "ERROR: " CRESET
        "no arguments allowed for %s\n", argv[2]);
            return EXIT_FAILURE;
    }
    fprintf(stdout, YEL "Root module" CRESET
        "  : %s\n", getenv("ROOTMODULE"));
    char *opam_bindir = getenv("OPAMBINDIR");
    fprintf(stdout, YEL "  OPAMBINDIR" CRESET
        " : %s\n", opam_bindir);
    char *opam_root = getenv("OPAMROOT");
    fprintf(stdout, YEL "  OPAMROOT" CRESET
        "   : %s\n", opam_root);
    fprintf(stdout, YEL "  OPAMSWITCH" CRESET
        " : %s\n", getenv("OPAMSWITCH"));
    fprintf(stdout, YEL "  config file" CRESET
        ": %s\n", argv[2]);
    fprintf(stdout, "\n");

    fprintf(stdout, RED "WARNING: " CRESET
        "reconfiguring opam installation to support Bazel operations.\n");
    fprintf(stdout, "Bazel builds require network access.\n");

    char *precmd = "init --reinit "
        "--no "
        "--bypass-checks "
        "--no-opamrc "
        "--quiet ";
    int ct = strlen(opam_bindir) + strlen(opam_root) + strlen(precmd) + strlen(argv[2]) + 20; /* account for chars in format string */
    char *cmd = malloc(ct);
    int written = snprintf(cmd, ct,
                           "%s/opam %s --root %s %s",
                           opam_bindir, precmd, opam_root,
                           argv[2]);
    /* printf("cwd: %s\n", getcwd(NULL,0)); */
    fprintf(stdout, YEL "cmd" CRESET ": %s\n\n", cmd);
    system(cmd);
    free(cmd);
}
