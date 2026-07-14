/* src/include/pg_config.h.  Generated from pg_config.h.in by configure.  */
/* src/include/pg_config.h.in.  Generated from configure.ac by autoheader.  */

/* Size of a disk block --- this also limits the size of a tuple. You can set
   it bigger if you need bigger tuples (although TOAST should reduce the need
   to have large tuples, since fields can be spread across multiple tuples).
   BLCKSZ must be a power of 2. The maximum possible value of BLCKSZ is
   currently 2^15 (32768). This is determined by the 15-bit widths of the
   lp_off and lp_len fields in ItemIdData (see include/storage/itemid.h).
   Changing BLCKSZ requires an initdb. */
#define BLCKSZ 8192

/* Saved arguments from configure */
#if defined USE_OPENSSL
#define CONFIGURE_ARGS " '--with-openssl' '--without-readline'"
#else
#define CONFIGURE_ARGS " '--without-readline'"
#endif

/* Define to the default TCP port number on which the server listens and to
   which clients will try to connect. This can be overridden at run-time, but
   it's convenient if your clients have the right default compiled in.
   (--with-pgport=PORTNUM) */
#define DEF_PGPORT 5432

/* Define to the default TCP port number as a string constant. */
#define DEF_PGPORT_STR "5432"

/* Define to 1 to build client libraries as thread-safe code.
   (--enable-thread-safety) */
#define ENABLE_THREAD_SAFETY 1

/* Define to 1 if you have the `ASN1_STRING_get0_data' function. */
#define HAVE_ASN1_STRING_GET0_DATA 1

/* Define to 1 if you want to use atomics if available. */
#define HAVE_ATOMICS 1

/* Define to 1 if you have the `backtrace_symbols' function. */
#define HAVE_BACKTRACE_SYMBOLS 1

/* /\* Define to 1 if you have the `BIO_get_data' function. *\/ */
#define HAVE_BIO_GET_DATA 1

/* /\* Define to 1 if you have the `BIO_meth_new' function. *\/ */
#define HAVE_BIO_METH_NEW 1

/* Define to 1 if you have the `crypto' library (-lcrypto). */
#define HAVE_LIBCRYPTO 1

/* Define to 1 if you have the `m' library (-lm). */
#define HAVE_LIBM 1

/* Define to 1 if you have the `ssl' library (-lssl). */
#define HAVE_LIBSSL 1

/* Define to 1 if `long int' works and is 64 bits. */
#define HAVE_LONG_INT_64 1

/* Define to 1 if you have the `OPENSSL_init_ssl' function. */
#define HAVE_OPENSSL_INIT_SSL 1

/* Define to 1 if you have the `SSL_CTX_set_cert_cb' function. */
#define HAVE_SSL_CTX_SET_CERT_CB 1

/* Define to 1 if stdbool.h conforms to C99. */
#define HAVE_STDBOOL_H 1

/* Define to 1 if you have the <stdint.h> header file. */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

#ifndef __WIN32__
/* Define to 1 if you have the `strerror_r' function. */
#define HAVE_STRERROR_R 1

#ifdef __APPLE__
#define STRERROR_R_INT 1
#endif

/* Define to 1 if you have the <xlocale.h> header file. */
#ifdef __APPLE__
#define HAVE_XLOCALE_H 1
#endif

#endif

// windows does not have that header
#ifndef _WIN32
/* Define to 1 if you have the <strings.h> header file. */
#define HAVE_STRINGS_H 1

#endif

/* Define to 1 if you have the `strnlen' function. */
#define HAVE_STRNLEN 1

/* Define to 1 if your compiler understands `typeof' or something similar. */
#define HAVE_TYPEOF 1

/* Define to 1 if you have the `X509_get_signature_info' function. */
#define HAVE_X509_GET_SIGNATURE_INFO 1

/* Define to 1 if you have the `X509_get_signature_nid' function. */
#define HAVE_X509_GET_SIGNATURE_NID 1

#ifndef _WIN32
/* Define to 1 if your compiler understands _Static_assert. */
#define HAVE__STATIC_ASSERT 1
#endif

/* Define as the maximum alignment requirement of any C data type. */
#define MAXIMUM_ALIGNOF 8

/* /\* Define bytes to use libc memset(). *\/ */
#define MEMSET_LOOP_LIMIT 1024

/* Define to the OpenSSL API version in use. This avoids deprecation warnings
   from newer OpenSSL versions. */
#define OPENSSL_API_COMPAT 0x10001000L

/* Define to the address where bug reports for this package should be sent. */
#define PACKAGE_BUGREPORT "pgsql-bugs@lists.postgresql.org"

/* Define to the full name of this package. */
#define PACKAGE_NAME "PostgreSQL"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "PostgreSQL 16.0"

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME "postgresql"

/* Define to the home page for this package. */
#define PACKAGE_URL "https://www.postgresql.org/"

/* Define to the version of this package. */
#define PACKAGE_VERSION "16.0"

#ifndef _WIN32
/* Define to the name of a signed 128-bit integer type. */
#define PG_INT128_TYPE __int128
#endif

/* Define to the name of a signed 64-bit integer type. */
#define PG_INT64_TYPE long int

/* Define to the name of the default PostgreSQL service principal in Kerberos
   (GSSAPI). (--with-krb-srvnam=NAME) */
#define PG_KRB_SRVNAM "postgres"

/* PostgreSQL major version as a string */
#define PG_MAJORVERSION "16"

/* PostgreSQL major version number */
#define PG_MAJORVERSION_NUM 16

/* PostgreSQL minor version number */
#define PG_MINORVERSION_NUM 0

/* Define to best printf format archetype, usually gnu_printf if available. */
#define PG_PRINTF_ATTRIBUTE gnu_printf

/* Define to 1 to use <stdbool.h> to define type bool. */
#define PG_USE_STDBOOL 1

/* PostgreSQL version as a string */
#define PG_VERSION "16.0"

/* PostgreSQL version as a number */
#define PG_VERSION_NUM 160000

/* A string containing the version number, platform, and C compiler */
#define PG_VERSION_STR "PostgreSQL 18.0"

/* RELSEG_SIZE is the maximum number of blocks allowed in one disk file. Thus,
   the maximum size of a single file is RELSEG_SIZE * BLCKSZ; relations bigger
   than that are divided into multiple files. RELSEG_SIZE * BLCKSZ must be
   less than your OS' limit on file size. This is often 2 GB or 4GB in a
   32-bit operating system, unless you have large file support enabled. By
   default, we make the limit 1 GB to avoid any possible integer-overflow
   problems within the OS. A limit smaller than necessary only means we divide
   a large relation into more chunks than necessary, so it seems best to err
   in the direction of a small limit. A power-of-2 value is recommended to
   save a few cycles in md.c, but is not absolutely required. Changing
   RELSEG_SIZE requires an initdb. */
#define RELSEG_SIZE 131072

/* The size of `bool', as computed by sizeof. */
#define SIZEOF_BOOL 1

/* The size of `long', as computed by sizeof. */
#define SIZEOF_LONG 8

/* The size of `off_t', as computed by sizeof. */
#define SIZEOF_OFF_T 8

/* The size of `size_t', as computed by sizeof. */
#define SIZEOF_SIZE_T 8

/* The size of `void *', as computed by sizeof. */
#define SIZEOF_VOID_P 8

/* Define to 1 if you have the ANSI C header files. */
#define STDC_HEADERS 1

/* Define WORDS_BIGENDIAN to 1 if your processor stores words with the most
   significant byte first (like Motorola and SPARC, unlike Intel). */
#if defined AC_APPLE_UNIVERSAL_BUILD
#if defined __BIG_ENDIAN__
#define WORDS_BIGENDIAN 1
#endif
#else
#ifndef WORDS_BIGENDIAN
/* #  undef WORDS_BIGENDIAN */
#endif
#endif

/* Size of a WAL file block. This need have no particular relation to BLCKSZ.
   XLOG_BLCKSZ must be a power of 2, and if your system supports O_DIRECT I/O,
   XLOG_BLCKSZ must be a multiple of the alignment requirement for direct-I/O
   buffers, else direct I/O may fail. Changing XLOG_BLCKSZ requires an initdb.
   */
#define XLOG_BLCKSZ 8192

/* Define to `__inline__' or `__inline' if that's what the C compiler
   calls it, or to nothing if 'inline' is not supported under any name.  */
#ifndef __cplusplus
/* #undef inline */
#endif

/* Define to keyword to use for C99 restrict support, or to nothing if not
   supported */
#define pg_restrict __restrict

/* Define to the equivalent of the C99 'restrict' keyword, or to
   nothing if this is not supported.  Do not define if restrict is
   supported directly.  */
#define restrict __restrict
/* Work around a bug in Sun C++: it does not support _Restrict or
   __restrict__, even though the corresponding Sun C compiler ends up with
   "#define restrict _Restrict" or "#define restrict __restrict__" in the
   previous line.  Perhaps some future version of Sun C++ will work with
   restrict; if so, hopefully it defines __RESTRICT like Sun C does.  */
#if defined __SUNPRO_CC && !defined __RESTRICT
#define _Restrict
#define __restrict__
#endif

/* Define to how the compiler spells `typeof'. */
/* #undef typeof */

/* Define to 1 if you have the `HMAC_CTX_free' function. */
#define HAVE_HMAC_CTX_FREE 1
/* Define to 1 if you have the `HMAC_CTX_new' function. */
#define HAVE_HMAC_CTX_NEW 1

/* Define to the appropriate printf length modifier for 64-bit ints. */
#define INT64_MODIFIER "l"

#if defined _WIN32
#define HAVE_INET_ATON 1
#endif

#if defined _WIN32
#define HAVE_DECL_STRNLEN 1
#endif
