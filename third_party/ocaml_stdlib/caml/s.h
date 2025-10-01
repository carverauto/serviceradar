/* runtime/caml/s.h.  Generated from s.h.in by configure.  */
/**************************************************************************/
/*                                                                        */
/*                                 OCaml                                  */
/*                                                                        */
/*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           */
/*                                                                        */
/*   Copyright 1996 Institut National de Recherche en Informatique et     */
/*     en Automatique.                                                    */
/*                                                                        */
/*   All rights reserved.  This file is distributed under the terms of    */
/*   the GNU Lesser General Public License version 2.1, with the          */
/*   special exception on linking described in the file LICENSE.          */
/*                                                                        */
/**************************************************************************/

/* Operating system and standard library configuration. */

/* 0. Operating system type string. */

#define OCAML_OS_TYPE "Unix"
/* #define OCAML_OS_TYPE "Unix" */
/* #define OCAML_OS_TYPE "Win32" */
/* #define OCAML_OS_TYPE "MacOS" */

/* 1. For the runtime system. */

#define POSIX_SIGNALS 1

/* Define POSIX_SIGNALS if signal handling is POSIX-compliant.
   In particular, sigaction(), sigprocmask() and the operations on
   sigset_t are provided. */

/* #undef BSD_SIGNALS */

/* Define BSD_SIGNALS if signal handlers have the BSD semantics: the handler
   remains attached to the signal when the signal is received. Leave it
   undefined if signal handlers have the System V semantics: the signal
   resets the behavior to default. */

#define SUPPORT_DYNAMIC_LINKING 1

/* Define SUPPORT_DYNAMIC_LINKING if dynamic loading of C stub code
   via dlopen() is available. */

#define HAS_FULL_THREAD_VARIABLES 1

/* Define HAS_FULL_THREAD_VARIABLES if thread-local storage is fully supported,
   including across DLLs. This is not the case with macOS and with Windows +
   MinGW-w64. */

#define HAS_C99_FLOAT_OPS 1

/* Define HAS_C99_FLOAT_OPS if <math.h> conforms to ISO C99.
   In particular, it should provide expm1(), log1p(), hypot(), fma(),
   exp2(), log2(), cbrt(), acosh(), asinh(), atanh(), erf(), erfc(),
   trunc(), round(), copysign(). */

#define HAS_WORKING_FMA 1

/* Define HAS_WORKING_FMA if the fma function is correctly implemented. The
   newlib library (intentionally) just has return x * y + z. This hatch is
   also used for https://sourceforge.net/p/mingw-w64/bugs/848/ */

#define HAS_WORKING_ROUND 1

/* Define HAS_WORKING_ROUND is the round function is correctly implemented. This
   hatch exists primarily for https://sourceforge.net/p/mingw-w64/bugs/573/ */

#define HAS_GETENTROPY 1

#define HAS_GETRUSAGE 1

#define HAS_TIMES 1

#define HAS_SECURE_GETENV 1

/* #undef HAS___SECURE_GETENV */

/* #undef HAS_ISSETUGID */

#define HAS_STDATOMIC_H 1

#define HAS_SYS_MMAN_H 1

/* 2. For the Unix library. */

#define HAS_SOCKETS 1

/* Define HAS_SOCKETS if you have BSD sockets. */

/* #undef HAS_SOCKETPAIR */

/* Define HAS_SOCKETPAIR if you have the socketpair function. Only
   relevant on Windows. */

#define HAS_SOCKLEN_T 1

/* Define HAS_SOCKLEN_T if the type socklen_t is defined in
   /usr/include/sys/socket.h. */

/* #undef HAS_AFUNIX_H */

/* Define HAS_AFUNIX_H if you have <afunix.h>. */

#define HAS_INET_ATON 1

#define HAS_IPV6 1

#define HAS_STDINT_H 1

/* #undef HAS_PTHREAD_NP_H */

#define HAS_UNISTD 1

/* Define HAS_UNISTD if you have /usr/include/unistd.h. */

#define HAS_DIRENT 1

/* Define HAS_DIRENT if you have /usr/include/dirent.h and the result of
   readdir() is of type struct dirent *.
   Otherwise, we'll load /usr/include/sys/dir.h, and readdir() is expected to
   return a struct direct *. */

#define HAS_REWINDDIR 1

/* Define HAS_REWINDDIR if you have rewinddir(). */

#define HAS_LOCKF 1

/* Define HAS_LOCKF if the library provides the lockf() function. */

#define HAS_MKFIFO 1

/* Define HAS_MKFIFO if the library provides the mkfifo() function. */

#define HAS_GETCWD 1

/* Define HAS_GETCWD if the library provides the getcwd() function. */

#define HAS_SYSTEM 1

/* Define HAS_SYSTEM if the library provides the system() function. */

#define HAS_UTIME 1
#define HAS_UTIMES 1

/* Define HAS_UTIME if you have /usr/include/utime.h and the library
   provides utime(). Define HAS_UTIMES if the library provides utimes(). */

#define HAS_FCHMOD 1

/* Define HAS_FCHMOD if you have fchmod() and fchown(). */

#define HAS_TRUNCATE 1

/* Define HAS_TRUNCATE if you have truncate() and
   ftruncate(). */

#define HAS_SELECT 1

/* Define HAS_SELECT if you have select(). */

#define HAS_SYS_SELECT_H 1

/* Define HAS_SYS_SELECT_H if /usr/include/sys/select.h exists
   and should be included before using select(). */

#define HAS_NANOSLEEP 1
/* Define HAS_NANOSLEEP if you have nanosleep(). */

#define HAS_SYMLINK 1

/* Define HAS_SYMLINK if you have symlink() and readlink() and lstat(). */

#define HAS_REALPATH 1
/* Define HAS_REALPATH if you have realpath(). */

#define HAS_WAIT4 1
#define HAS_WAITPID 1

/* Define HAS_WAIT4 if you have wait4().
   Define HAS_WAITPID if you have waitpid(). */

#define HAS_GETGROUPS 1

/* Define HAS_GETGROUPS if you have getgroups(). */

#define HAS_SETGROUPS 1

/* Define HAS_SETGROUPS if you have setgroups(). */

#define HAS_INITGROUPS 1

/* Define HAS_INITGROUPS if you have initgroups(). */

#define HAS_TERMIOS 1

/* Define HAS_TERMIOS if you have /usr/include/termios.h and it is
   Posix-compliant. */

#define HAS_SETITIMER 1

/* Define HAS_SETITIMER if you have setitimer(). */

#define HAS_GETHOSTNAME 1

/* Define HAS_GETHOSTNAME if you have gethostname(). */

#define HAS_UNAME 1

/* Define HAS_UNAME if you have uname(). */

#define HAS_GETTIMEOFDAY 1

/* Define HAS_GETTIMEOFDAY if you have gettimeofday(). */

#define HAS_MKTIME 1

/* Define HAS_MKTIME if you have mktime(). */

#define HAS_SETSID 1

/* Define HAS_SETSID if you have setsid(). */

#define HAS_PUTENV 1

/* Define HAS_PUTENV if you have putenv(). */

#define HAS_SETENV_UNSETENV 1

/* Define HAS_SETENV_UNSETENV if you have setenv() and unsetenv(). */

#define HAS_LOCALE_H 1

/* Define HAS_LOCALE_H if you have the include file <locale.h> and the
   uselocale() function. */

/* #undef HAS_XLOCALE_H */

/* Define HAS_XLOCALE_H if you have the include file <xlocale.h> and the
   uselocale() function. */

#define HAS_STRTOD_L 1

/* Define HAS_STRTOD_L if you have strtod_l */

#define HAS_MMAP 1

/* Define HAS_MMAP if you have the include file <sys/mman.h> and the
   functions mmap() and munmap(). */

#define HAS_PWRITE 1

#define HAS_NANOSECOND_STAT 1

#define HAS_GETHOSTBYNAME_R 6

/* Define HAS_GETHOSTBYNAME_R if gethostbyname_r() is available.
   The value of this symbol is the number of arguments of
   gethostbyname_r(): either 5 or 6 depending on prototype.
   (5 is the Solaris version, 6 is the Linux version). */

#define HAS_GETHOSTBYADDR_R 8

/* Define HAS_GETHOSTBYADDR_R if gethostbyname_r() is available.
   The value of this symbol is the number of arguments of
   gethostbyaddr_r(): either 7 or 8 depending on prototype.
   (7 is the Solaris version, 8 is the Linux version). */

#define HAS_MKSTEMP 1

#define HAS_NICE 1

/* Define HAS_NICE if you have nice(). */

#define HAS_DUP3 1

#define HAS_PIPE2 1

#define HAS_ACCEPT4 1

#define HAS_GETAUXVAL 1

#define HAS_SYS_SHM_H 1

#define HAS_SHMAT 1

#define HAS_EXECVPE 1

#define HAS_POSIX_SPAWN 1

#define HAS_SIGWAIT 1

#define HAS_HUGE_PAGES 1

#define HUGE_PAGE_SIZE (4 * 1024 * 1024)

/* #undef HAS_LIBUNWIND */

/* #undef HAS_BROKEN_PRINTF */

/* #undef HAS_STRERROR */

#define HAS_POSIX_MONOTONIC_CLOCK 1

/* #undef HAS_CLOCK_GETTIME_NSEC_NP */

#define HAS_GNU_GETAFFINITY_NP 1
/* #undef HAS_BSD_GETAFFINITY_NP */

/* #undef HAS_ZSTD */
