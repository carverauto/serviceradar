#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#ifndef WIN32
# include <unistd.h>
#else
# define ssize_t int
# include <io.h>
# include <sys/types.h>
#endif

#include "liblogc.h"
#include "utarray.h"
#include "utstring.h"
#include "sexp.h"
#include "sexp_ops.h"

#include "dune-package.h"

#define DEBUG_LEVEL debug_dune
int  DEBUG_LEVEL;
#define TRACE_FLAG trace_dune
bool TRACE_FLAG;

char pstr[8192];
FILE  *instream = NULL;
int    fd;
static size_t read_len;
static char *inbuf = NULL;
static char *check_buf = NULL;

char * dune_lang_version = NULL;

void _handle_error(sexp_errcode_t sexperrno)
{
    switch(sexperrno) {
    case SEXP_ERR_IO_EMPTY:
        printf("io empty\n");
        break;
    case SEXP_ERR_IO:
        printf("err: io\n");
        break;
    case SEXP_ERR_BADFORM:
        printf("err: badform\n");
        break;
    case SEXP_ERR_MEMORY:
        printf("err: memory\n");
        break;
    case SEXP_ERR_MEM_LIMIT:
        printf("err: mem limit\n");
        break;
    case SEXP_ERR_BADCONTENT:
        printf("err: badcontent\n");
        break;
    case SEXP_ERR_NULLSTRING:
        printf("err: nullstring\n");
        break;
    case SEXP_ERR_BUFFER_FULL:
        printf("err: io\n");
        break;
    case SEXP_ERR_BAD_PARAM:
        printf("err: bad param\n");
        break;
    case SEXP_ERR_BAD_STACK:
        printf("err: bad stack\n");
        break;
    case  SEXP_ERR_BAD_CONSTRUCTOR:
        printf("err: bad constructor\n");
        break;
    case SEXP_ERR_UNKNOWN_STATE:
        printf("err: unknown state\n");
        break;
    case SEXP_ERR_INCOMPLETE:
        printf("err: incomplete\n");
        break;
        break;
    default:
        printf("err: other\n");
    }
}

EXPORT void dune_package_open(char *dune_pkg_file)
{
    size_t file_size;
    struct stat stbuf;

    errno = 0;
    fd = open(dune_pkg_file, O_RDONLY);
    if (fd < 0) {
        perror(dune_pkg_file);
        log_error("open error: %s\n", dune_pkg_file);
        goto failure;
    }

    /* log_debug("fopened %s", dunefile_name); */
    if ((fstat(fd, &stbuf) != 0) || (!S_ISREG(stbuf.st_mode))) {
        /* Handle error */
        perror(dune_pkg_file);
        log_error("fstat error: %s\n", dune_pkg_file);
        close(fd);
        goto failure;
    }

    file_size = stbuf.st_size;
    LOG_DEBUG(1, "filesize: %d", file_size);

    inbuf = (char*)calloc(file_size + 1, sizeof(char));
    if (inbuf == NULL) {
        perror(dune_pkg_file);
        log_error("malloc fail file_size %d", file_size);
        close(fd);
        goto failure;
    }
    check_buf = (char*)calloc(file_size + 1, sizeof(char));
    if (check_buf == NULL) {
        perror(dune_pkg_file);
        log_error("malloc fail file_size %d", file_size);
        close(fd);
        goto failure;
    }

    /* FIXME: what about e.g. unicode in string literals? */
    errno = 0;
    instream = fdopen(fd, "r");
    if (instream == NULL) {
        perror(dune_pkg_file);
        log_error("fdopen failure: %s", dune_pkg_file);
        close(fd);
        goto failure;
    } else {
        LOG_DEBUG(1, "fdopened %s", dune_pkg_file);
        /* utstring_body(dunefile_name)); */
    }

    read_len = fread(inbuf, 1, file_size, instream);
    /* FIXME: error check */
    inbuf[read_len] = '\0';       /* make sure it's properly terminated */

    _set_dune_lang_version();

    return;
 failure:
    exit(EXIT_FAILURE);
}

EXPORT void dune_package_close(void)
{
    free(inbuf);
    free(check_buf);
    fclose(instream);
    close(fd);
}

/*
  WARNING: this is for recent dune versions.
  Earlier versions (e.g. 4.14.0, pkg base) used:
   (foreign_archives (archives (for all) (files libbase_stubs.a)))
   or  (foreign_archives libbase_stubs.a)
   that's with dune lang 2.8, 2.9
   with dune lang 3.10 (3.0?) we get (files ... (stublibs ...))
 */

EXPORT UT_array *dune_package_files_fld(char *fldname)
{
    sexp_t *sx    = NULL;
    sexp_t *filesexp = NULL;
    sexp_t *fldsexp = NULL;
    pcont_t *cc = NULL;

    /* printf("dune lang version: %s\n", dune_lang_version); */

    UT_array *values;
    utarray_new(values, &ut_str_icd);

    if (cc == NULL) { cc = init_continuation(inbuf); }

    sx = (sexp_t *)iparse_sexp(inbuf, read_len, cc);
    while (sx != NULL) {
        filesexp = find_sexp("files",sx);
        if (filesexp != NULL) {
            print_sexp(pstr, 1024, filesexp);
            /* printf("files = %s\n", pstr); */
            fldsexp = find_sexp(fldname, filesexp);
            if (fldsexp != NULL) {
                sexp_t *valsexp = fldsexp->next;
                /* print_sexp(pstr, 1024, valsexp); */
                /* printf("values = %s\n", pstr); */
                if (valsexp->ty == SEXP_LIST) {
                    /* printf("list len: %d\n", sexp_list_length(valsexp)); */
                    while(valsexp != NULL) {
                        if (valsexp->ty == SEXP_VALUE) {
                            utarray_push_back(values, &(valsexp->val));
                            /* printf("val=%s\n", valsexp->val); */
                            valsexp = NULL;
                        } else {
                            if (hd_sexp(valsexp)->ty == SEXP_VALUE) {
                                utarray_push_back(values, &(hd_sexp(valsexp)->val));
                                /* printf("VAL=%s\n", hd_sexp(valsexp)->val); */
                            }
                            valsexp = tl_sexp(valsexp);
                        }
                    }
                }
            }
            break;
        }
        destroy_sexp(sx);
        sx = (sexp_t *)iparse_sexp(inbuf, read_len, cc);
    }
    fflush(NULL);
    destroy_continuation(cc);
    destroy_sexp(sx);
    sexp_cleanup();
    return values;
}

LOCAL void _set_dune_lang_version(void)
{
    sexp_t *sx    = NULL;
    sexp_t *keysexp = NULL;
    pcont_t *cc = NULL;

    if (cc == NULL) { cc = init_continuation(inbuf); }

    sx = (sexp_t *)iparse_sexp(inbuf, read_len, cc);
    keysexp = find_sexp("lang",sx);
    if (keysexp != NULL) {
        /* print_sexp(pstr, 1024, keysexp); */
        /* printf("lang = %s\n", pstr); */
        sexp_t *valsexp = keysexp->next;
        /* print_sexp(pstr, 1024, valsexp); */
        /* printf("val = %s\n", valsexp->val); */
        valsexp = valsexp->next;
        /* print_sexp(pstr, 1024, valsexp); */
        /* printf("version = %s\n", valsexp->val); */
        dune_lang_version = strdup(valsexp->val);
        destroy_sexp(sx);
        fflush(NULL);
    }
    destroy_continuation(cc);
}
