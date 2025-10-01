#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>              /* open() */
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if INTERFACE
#ifdef __linux__
#include <linux/limits.h>
#include <sys/types.h>
#include <sys/wait.h>
#else
#include <limits.h>
#endif
#endif

#define BUFSZ 4096

/* #define TRACING */

#if INTERFACE
#include "utstring.h"
#endif

#include "liblogc.h"
#include "spawn_cmd.h"

extern int errnum;
/* bool local_opam; */

/* UT_array *opam_packages; */

#define DEBUG_LEVEL debug_tools_opam
extern int  DEBUG_LEVEL;
#define TRACE_FLAG trace_tools_opam
extern bool TRACE_FLAG;

void dump_pipe(int FILEDES, int the_pipe)
{
    (void)FILEDES;
#if defined(TRACING)
    if (FILEDES == STDOUT_FILENO)
        log_trace("dump stdout_pipe: ");
    else
        log_trace("dump stderr_pipe: ");
#endif
    ssize_t read_ct;
    (void)read_ct;
    char buf[256];

    /* char xbuf[4096]; */
    /* read_ct = read(the_pipe, xbuf, 4096); */
    /* /\* if (mibl_debug) { *\/ */
    /*     for (int i=0; i<20; i++) { */
    /*         printf("%02x ", xbuf[i]); */
    /*     } */
    /*     printf("\n"); */
    /* /\* } *\/ */

    /* if (strncmp(xbuf, */
    /*             "\033[31m" // RED */
    /*             "[ERROR]" */
    /*             CRESET    // \033[0m */
    /*             " Variable ocaml-variants:version not found", */
    /*             41) == 0) { */
    /*     log_debug("ocaml-variants:version NOT FOUND"); */
    /*     return; */
    /* } */
    /* else if (strncmp(xbuf, */
    /* /\* "It seems you have not updated your repositories for a while..." *\/ */
    /*                  "[NOTE] It seems", */
    /*                  14) == 0) { */
    /*     printf("opam repository needs UPDATE \n"); */
    /*     /\* return; *\/ */
    /* /\* } else { *\/ */
    /* /\*     if (mibl_debug) *\/ */
    /* /\*         printf("X: %s\n", xbuf); *\/ */
    /* } */

    FILE *instream = NULL;
    errno = 0;
    instream = fdopen(the_pipe, "r");
    if (instream == NULL) {
        /* Handle error */
        log_error("fdopen failure on pipe", "");
        perror(NULL);
        return;
    } else {
/* #if defined(PROFILE_fastbuild) */
/*         log_debug("fdopened pipe", ""); */
/* #endif */
    }
    while (fgets(buf, sizeof(buf), instream)) {
        printf("%s", buf);
    }

    /* for (;;) */
    /* { */
    /*     read_ct = read(the_pipe, buf, sizeof(buf)); */
    /*     printf("read_ct: %zd\n", read_ct); */
    /*     if (read_ct > 0) */
    /*     { */
    /*         printf("%s\n", buf); */
    /*     } */
    /*     else */
    /*     { */
    /*         break; */
    /*     } */
    /* } */
}

/* spawn_cmd
   run posix_spawn with stdout and stderr redirected to pipes
 */
EXPORT int spawn_cmd(char *executable, int argc, char *argv[], int *_stdout_pipe, int *_stderr_pipe)
{
    TRACE_ENTRY;
    if (verbose) {
        UT_string *cmd_str;
        utstring_new(cmd_str);
        for (int i =0; i < argc; i++) {
            utstring_printf(cmd_str, "%s ", (char*)argv[i]);
        }
        log_info("%s", utstring_body(cmd_str));
        /* log_info("obazl:"); */
        printf(YEL "EXEC: " CMDCLR);
        printf("%s ", utstring_body(cmd_str));
        printf(CRESET "\n");
    }

    /* if (dry_run) return 0; */

    pid_t pid;
    int rc;

    int stdout_pipe[2];
    int stderr_pipe[2];

    errno = 0;
    rc = pipe(stdout_pipe);
    if (rc != 0) {
        log_error("pipe(stdout_pipe) fail: %s", strerror(errno));
        fprintf(stdout, "pipe(stdout_pipe) fail: %s\n", strerror(errno));
        exit(EXIT_FAILURE);
    }

    errno = 0;
    rc = pipe(stderr_pipe);
    if (rc != 0) {
        log_error("pipe(stderr_pipe) fail: %s", strerror(errno));
        fprintf(stdout, "pipe(stderr_pipe) fail: %s\n", strerror(errno));
        exit(EXIT_FAILURE);
    }

    extern char **environ;

    /* tell posix_spawn to redirect stdout/stderr */
    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);

    /* int DEVNULL_FILENO = open("/dev/null", O_WRONLY); */

    /* stdout > stdout_pipe[1] */
    if ((rc = posix_spawn_file_actions_adddup2(&action,
                                               stdout_pipe[1],
                                               STDOUT_FILENO))) {
        perror("posix_spawn_file_actions_adddup2 stdout > stdout_pipe[1]");
        posix_spawn_file_actions_destroy(&action);
        return rc;
    }
    /* why addclose pipe[0]? */
    posix_spawn_file_actions_addclose(&action, stdout_pipe[0]);

    /* stderr > stderr_pipe[1] */
    if ((rc = posix_spawn_file_actions_adddup2(&action,
                                               stderr_pipe[1],
                                               STDERR_FILENO))) {
        perror("posix_spawn_file_actions_adddup2 stderr > stderr_pipe[1]");
        posix_spawn_file_actions_destroy(&action);
        return rc;
    }
   posix_spawn_file_actions_addclose(&action, stderr_pipe[0]);

    errno = 0;
    rc = posix_spawnp(&pid, executable, &action, NULL, argv, environ);

    if (rc == 0) {
        LOG_DEBUG(0, "posix_spawn child pid: %i", pid);
        int waitrc = waitpid(pid, &rc, WUNTRACED);
        if (waitrc == -1) {
            perror("spawn_cmd waitpid error");
            log_error("spawn_cmd");
            posix_spawn_file_actions_destroy(&action);
            return -1;
        } else {
            LOG_TRACE(0, "waitpid rc: %d", waitrc);
            if ( WIFEXITED(rc) ) {
                // terminated normally by a call to _exit(2) or exit(3).
                LOG_DEBUG(0, "WIFEXITED(%d)", rc);
                LOG_DEBUG(0, "WEXITSTATUS(%d)", WEXITSTATUS(rc));
                /* "widow" the pipe (delivers EOF to reader)  */
                close(stdout_pipe[1]);
                /* dump_pipe(STDOUT_FILENO, stdout_pipe[0]); */
                /* close(stdout_pipe[0]); */
                *_stdout_pipe = stdout_pipe[0];

                /* "widow" the pipe (delivers EOF to reader)  */
                close(stderr_pipe[1]);
                /* dump_pipe(STDERR_FILENO, stderr_pipe[0]); */
                /* close(stderr_pipe[0]); */
                *_stderr_pipe = stderr_pipe[0];
                posix_spawn_file_actions_destroy(&action);

                errno = WEXITSTATUS(rc);
                return 0;
            }
            else if (WIFSIGNALED(rc)) {
                // terminated due to receipt of a signal
                log_error("WIFSIGNALED(rc)");
                log_error("WTERMSIG: %d", WTERMSIG(rc));
#ifdef WCOREDUMP
                log_error("WCOREDUMP?: %d", WCOREDUMP(rc));
#endif
                posix_spawn_file_actions_destroy(&action);
                return -1;
            } else if (WIFSTOPPED(rc)) {
                /* process has not terminated, but has stopped and can
                   be restarted. This macro can be true only if the
                   wait call specified the WUNTRACED option or if the
                   child process is being traced (see ptrace(2)). */
                log_error("WIFSTOPPED(rc)");
                log_error("WSTOPSIG: %d", WSTOPSIG(rc));
                posix_spawn_file_actions_destroy(&action);
                return -1;
            }
        }
        /* else { */
        /*     log_error("spawn_cmd: stopped or terminated child pid: %d", */
        /*               waitrc); */
        /*     posix_spawn_file_actions_destroy(&action); */
        /*     return -1; */
        /* } */
    } else {
        /* posix_spawnp rc != 0; does not set errno */
        log_fatal("spawn_cmd error rc: %d, %s", rc, strerror(rc));
        posix_spawn_file_actions_destroy(&action);
        return rc;
    }
    //  should not reach here?
    log_error("BAD FALL_THROUGH");
    return rc;
}

EXPORT int spawn_cmd_with_stdout(char *executable, int argc, char *argv[])
{
    TRACE_ENTRY;
    (void)argc;
    /* if (verbose || dry_run) { */
    /*     UT_string *cmd_str; */
    /*     utstring_new(cmd_str); */
    /*     for (int i =0; i < argc; i++) { */
    /*         utstring_printf(cmd_str, "%s ", (char*)argv[i]); */
    /*     } */
    /*     log_info("%s", utstring_body(cmd_str)); */
    /*     /\* log_info("obazl:"); *\/ */
    /*     printf(YEL "EXEC: " CMDCLR); */
    /*     printf("%s ", utstring_body(cmd_str)); */
    /*     printf(CRESET "\n"); */
    /* } */

    /* if (dry_run) return 0; */

    pid_t pid;
    int rc;

    extern char **environ;

    errno = 0;
    rc = posix_spawnp(&pid, executable, NULL, NULL, argv, environ);

    if (rc == 0) {
        LOG_DEBUG(0, "posix_spawn child pid: %i\n", pid);
        errno = 0;
        int waitrc = waitpid(pid, &rc, WUNTRACED);
        if (waitrc == -1) {
            perror("spawn_cmd waitpid error");
            log_error("spawn_cmd");
            /* posix_spawn_file_actions_destroy(&action); */
            return -1;
        } else {
            LOG_DEBUG(0, "waitpid rc: %d", waitrc);
            // child exit OK
            if ( WIFEXITED(rc) ) {
                // terminated normally by a call to _exit(2) or exit(3).
                LOG_DEBUG(0, "WIFEXITED(rc)", "");
                LOG_DEBUG(0, "WEXITSTATUS(rc): %d", WEXITSTATUS(rc));
                /* log_debug("WEXITSTATUS: %d", WEXITSTATUS(rc)); */
                /* "widow" the pipe (delivers EOF to reader)  */
                /* close(stdout_pipe[1]); */
                /* dump_pipe(STDOUT_FILENO, stdout_pipe[0]); */
                /* close(stdout_pipe[0]); */

                /* /\* "widow" the pipe (delivers EOF to reader)  *\/ */
                /* close(stderr_pipe[1]); */
                /* dump_pipe(STDERR_FILENO, stderr_pipe[0]); */
                /* close(stderr_pipe[0]); */

                fflush(stdout);
                fflush(stderr);
                return EXIT_SUCCESS;
            }
            else if (WIFSIGNALED(rc)) {
                // terminated due to receipt of a signal
                log_error("WIFSIGNALED(rc)");
                log_error("WTERMSIG: %d", WTERMSIG(rc));
                log_error("WCOREDUMP?: %d", WCOREDUMP(rc));
                return -1;
            } else if (WIFSTOPPED(rc)) {
                /* process has not terminated, but has stopped and can
                   be restarted. This macro can be true only if the
                   wait call specified the WUNTRACED option or if the
                   child process is being traced (see ptrace(2)). */
                log_error("WIFSTOPPED(rc)");
                log_error("WSTOPSIG: %d", WSTOPSIG(rc));
                return -1;
            }
        }
        /* else { */
        /*     log_error("spawn_cmd: stopped or terminated child pid: %d", */
        /*               waitrc); */
        /*     /\* posix_spawn_file_actions_destroy(&action); *\/ */
        /*     return -1; */
        /* } */
    } else {
        /* posix_spawnp rc != 0; does not set errno */
        log_fatal("spawn_cmd error rc: %d, %s", rc, strerror(rc));
        /* posix_spawn_file_actions_destroy(&action); */
        return rc;
    }
    //  should not reach here?
    log_error("BAD FALL_THROUGH");
    return rc;
}
