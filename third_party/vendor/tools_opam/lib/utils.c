#include <errno.h>
#include <dirent.h>
#include <stdbool.h>

#if EXPORT_INTERFACE
#include <stdio.h>
#endif

#ifdef __linux__
#include <linux/limits.h>
#else
#include <limits.h>
#endif

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "liblogc.h"
/* #include "utarray.h" */
#include "utstring.h"

#include "utils.h"

UT_string *runfiles_root;

extern int verbosity;
extern int log_writes;

#define DEBUG_LEVEL coswitch_debug
extern int  DEBUG_LEVEL;
#define TRACE_FLAG coswitch_trace
extern bool TRACE_FLAG;

EXPORT void copy_buildfile(char *src_file, UT_string *to_file)
{
    TRACE_ENTRY_MSG("dst: %s", utstring_body(to_file));
    LOG_DEBUG(2, "copy_buildfile src: %s",
              src_file);
    UT_string *src;
    utstring_new(src);

    int rc = access(src_file, F_OK);
    if (rc != 0) {
        perror(utstring_body(src));
        log_error("src file not found: %s", src_file);
        /* fprintf(stderr, "not found: %s\n", utstring_body(src)); */
        exit(EXIT_FAILURE);
        return;
    }

    /* if (coswitch_debug) { */
    /*     log_debug("copying %s to %s\n", */
    /*               utstring_body(src), */
    /*               utstring_body(to_file)); */
    /* } */
    errno = 0;
    rc = copyfile(src_file,
                  utstring_body(to_file));
    if (rc != 0) {
        log_error("copyfile: %s", strerror(errno));
        fprintf(stderr, "ERROR copyfile: %s", strerror(errno));
        log_error("Exiting");
        fprintf(stderr, "Exiting\n");
        exit(EXIT_FAILURE);
    }
    /* TRACE_EXIT; */
}

EXPORT void mkdir_r(const char *dir) {
    /* log_debug("mkdir_r %s", dir); */
    char tmp[512];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp),"%s",dir);
    len = strlen(tmp);
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    for (p = tmp + 1; *p; p++)
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, S_IRWXU);
            *p = '/';
        }
    mkdir(tmp, S_IRWXU);
}

int copyfile(char *fromfile, char *tofile)
{
    char ch;// source_file[20], target_file[20];

    FILE *source = fopen(fromfile, "r");
    if (source == NULL) {
        fprintf(stderr, "copyfile fopen fail on fromfile: %s\n", fromfile);
        exit(EXIT_FAILURE);
    }
    FILE *target = fopen(tofile, "w");
    if (target == NULL) {
        fclose(source);
        fprintf(stderr, "copyfile fopen fail on tofile: %s\n", tofile);
        exit(EXIT_FAILURE);
    }
    while ((ch = fgetc(source)) != EOF)
        fputc(ch, target);
/* #if defined(DEBUG_TRACE) */
/*         printf("File copy successful: %s -> %s.\n", */
/*                fromfile, tofile); */
/* #endif */
    fclose(source);
    fclose(target);
    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET " cp to %s\n", tofile);
    return 0;
}

void _copy_template(char *buildfile, UT_string *to_file) {
    UT_string *src;
    utstring_new(src);
    utstring_printf(src,
                    "%s/external/obazl/templates/%s",
                    /* "%s/obazl/templates/%s", */
                    utstring_body(runfiles_root),
                    buildfile);
    int rc = access(utstring_body(src), F_OK);
    if (rc != 0) {
        log_error("not found: %s", utstring_body(src));
        fprintf(stderr, "not found: %s\n", utstring_body(src));
        return;
    }

    /* if (debug) { */
    /*     log_debug("copying %s to %s\n", */
    /*               utstring_body(src), */
    /*               utstring_body(to_file)); */
    /* } */
    errno = 0;
    rc = copyfile(utstring_body(src),
                  utstring_body(to_file));
    if (rc != 0) {
        log_error("copyfile: %s", strerror(errno));
        fprintf(stderr, "ERROR copyfile: %s", strerror(errno));
        log_error("Exiting");
        fprintf(stderr, "Exiting\n");
        exit(EXIT_FAILURE);
    }
}

int write_template(char *pfx,
                   unsigned char input[], int len,
                   char *tofile)
{
    TRACE_ENTRY_MSG("%s", tofile);
    /* copy buf to file, replacing all "{{pfx}}" */
    /* we could count the nbr of occurrances and then
       allocate workbuf accordingly, but we know that
       at most a few dozen are possible, so just allow
       for 2K.
 */

    /* input[len] = '\0'; */
    /* printf("input: %s\n", (char*)input); */
    /* return 0; */

    char *work_buf = (char*)calloc(len + 4096, sizeof(char));
    if (work_buf == NULL) {
        //FIXME handle error
        printf("work_buf alloc error\n");
        exit(EXIT_FAILURE);
    }

    /* based on https://stackoverflow.com/questions/56043612/how-to-replace-a-part-of-a-string-with-another-substring */

    char *scanp = (char*)input;
    char *last_char = (char*)(input + len);

    size_t pfx_size = strlen(pfx);
    char *tag = "{{pfx}}";
    size_t tag_size = 7;
    char *wbp = (char*)work_buf;
    char *tagp = strstr((char*)scanp, tag);

    while ((tagp != NULL) && (scanp <= last_char)) {
        if (tagp == scanp) {
            memcpy (wbp, pfx, pfx_size+1);
            wbp += pfx_size;
            scanp += tag_size;
            tagp = strstr(scanp, tag);
        } else {
            while (scanp != tagp)
                *(wbp++) = *(scanp++);
        }
    }
    /* chars following last {{pfx}} */
    while (scanp < last_char) *(wbp++) = *(scanp++);
    *wbp = '\0';

    FILE *target = fopen(tofile, "w");
    if (target == NULL) {
        fprintf(stderr, "write_buf fopen fail on tofile: %s\n", tofile);
        exit(EXIT_FAILURE);
    }
    for (wbp = work_buf; *wbp != '\0'; wbp++) {
        fputc(*wbp, target);
    }
    free(work_buf);
    fclose(target);
    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET " cp to %s\n", tofile);
    return 0;
}

int write_buf(unsigned char buf[], int len, char *tofile)
{
    TRACE_ENTRY;
    FILE *target = fopen(tofile, "w");
    if (target == NULL) {
        fprintf(stderr, "write_buf fopen fail on tofile: %s\n", tofile);
        exit(EXIT_FAILURE);
    }
    for (int i = 0; i < len; i++) {
        fputc(buf[i], target);
    }
    fclose(target);
    if (verbosity > log_writes)
        fprintf(INFOFD, GRN "INFO" CRESET " cp to %s\n", tofile);
    return 0;
}


/* void emit_template(char *t) */
/* { */
/*     log_debug("emit_template: %s\n", t); */
/*     UT_string *ocaml_file; */
/*     utstring_new(ocaml_file); */
/*     /\* utstring_concat(ocaml_file, bzl_switch_pfx); *\/ */
/*     /\* utstring_printf(ocaml_file, "/ocaml/toolchains"); *\/ */
/*     utstring_printf(ocaml_file, "/bzl/host"); */
/*     mkdir_r(utstring_body(ocaml_file)); */
/*     utstring_printf(ocaml_file, "/BUILD.bazel"); */
/*     _copy_template("ocaml_toolchains.BUILD", ocaml_file); */
/*     utstring_free(ocaml_file); */
/* } */

/* for each file in templates: copy to same relative location in dest */

