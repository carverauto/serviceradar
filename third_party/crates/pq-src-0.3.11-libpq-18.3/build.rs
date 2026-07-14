use std::path::{Path, PathBuf};
use std::{env, fs};

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPORTS_BASE: &[&str] = &[
    "strlcat.c",
    "strlcpy.c",
    "snprintf.c",
    "pg_crc32c_sb8.c",
    "bsearch_arg.c",
    "chklocale.c",
    "inet_net_ntop.c",
    "noblock.c",
    "pg_bitutils.c",
    "pg_strong_random.c",
    "pgcheckdir.c",
    "pgmkdirp.c",
    "pgsleep.c",
    "pgstrcasecmp.c",
    "pgstrsignal.c",
    "pqsignal.c",
    "qsort.c",
    "quotes.c",
    "strerror.c",
    "tar.c",
    "explicit_bzero.c",
];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPORTS_LINUX: &[&str] = &["getpeereid.c"];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPORTS_MACOS: &[&str] = &[];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPORTS_WINDOWS: &[&str] = &[
    "getpeereid.c",
    "win32common.c",
    "win32dlopen.c",
    "win32env.c",
    "win32error.c",
    "win32fdatasync.c",
    "win32fseek.c",
    "win32getrusage.c",
    "win32gettimeofday.c",
    "win32link.c",
    "win32ntdll.c",
    "win32pread.c",
    "win32pwrite.c",
    "win32security.c",
    "win32setlocale.c",
    "win32stat.c",
    "win32gai_strerror.c",
    "open.c",
    "dirmod.c",
    "inet_aton.c",
];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBCOMMON_BASE: &[&str] = &[
    "file_perm.c",
    "encnames.c",
    "base64.c",
    "scram-common.c",
    "ip.c",
    "jsonapi.c",
    "kwlookup.c",
    "link-canary.c",
    "md5_common.c",
    "percentrepl.c",
    "pg_get_line.c",
    "pg_lzcompress.c",
    "pg_prng.c",
    "pgfnames.c",
    "psprintf.c",
    "rmtree.c",
    "saslprep.c",
    "string.c",
    "stringinfo.c",
    "unicode_norm.c",
    "username.c",
    "wait_error.c",
    "wchar.c",
    "fe_memutils.c",
    "restricted_token.c",
    "sprompt.c",
    "logging.c",
];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBCOMMON_OPENSSL: &[&str] = &["cryptohash_openssl.c", "hmac_openssl.c"];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBCOMMON_NOT_OPENSSL: &[&str] = &["cryptohash.c", "hmac.c", "md5.c", "sha1.c", "sha2.c"];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBCOMMON_NOT_WINDOWS: &[&str] = &[];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBCOMMON_WINDOWS: &[&str] = &["wchar.c"];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPQ_BASE: &[&str] = &[
    "fe-auth-scram.c",
    "fe-auth.c",
    "fe-cancel.c",
    "fe-connect.c",
    "fe-exec.c",
    "fe-lobj.c",
    "fe-misc.c",
    "fe-print.c",
    "fe-protocol3.c",
    "fe-secure.c",
    "fe-trace.c",
    "fe-auth-oauth.c",
    "legacy-pqsignal.c",
    "libpq-events.c",
    "pqexpbuffer.c",
];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPQ_OPENSSL: &[&str] = &["fe-secure-common.c", "fe-secure-openssl.c"];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPQ_NOT_WINDOWS: &[&str] = &[];

// If you update this file list also
// update the list of includes files in
// the Cargo.toml file
const LIBPQ_WINDOWS: &[&str] = &["fe-secure.c", "pthread-win32.c", "win32.c"];

fn unimplemented(os: &str, env: &str) -> ! {
    unimplemented!(
        "Building a bundled version of libpq is currently not supported for this combination of \
        OS and toolchain environment.\n\
        Target OS: '{os}', Target Environment: '{env}'\n\
        If you are interested in support for using a bundled libpq we are happy to accept patches \
        at https://github.com/sgrif/pq-sys/"
    );
}

macro_rules! make_test_for {
    ($name: ident, $test: literal) => {
        const $name: &str = concat!(
            r#"
#include<string.h>

int main() {"#,
            $test,
            r#"
}"#
        );
    };
}

make_test_for!(TEST_FOR_STRCHRNUL, r#"strchrnul("", 42);"#);
make_test_for!(TEST_FOR_STRSIGNAL, r#"strsignal(32);"#);

fn check_compiles(test: &str, mut command: cc::Build) -> bool {
    // Add necessary compiler-flags to make sure that undefined functions actually cause errors
    // NOTE: Starting with GCC 14 and Clang 16, this is default behaviour.
    // See:
    //   - https://gcc.gnu.org/gcc-14/porting_to.html#implicit-function-declaration
    //   - https://releases.llvm.org/16.0.0/tools/clang/docs/ReleaseNotes.html#potentially-breaking-changes
    command
        .flag_if_supported("-Werror=implicit-function-declaration") // GCC/Clang
        .flag_if_supported("/we4013"); // MSVC

    // Do not emit metadata for linking
    // NOTE: This allows libtest.a to be removed after the compilation,
    //       otherwise cargo would link against it
    command.cargo_metadata(false);

    // Write test.c file, try to compile it and return result
    let out = PathBuf::from(env::var("OUT_DIR").expect("Set by cargo"));
    let test_path = out.join("test.c");
    fs::write(&test_path, test).expect("Failed to write test file");
    let r = command.file(&test_path).try_compile("test");
    fs::remove_file(test_path).expect("Failed to remove test file");
    if let Err(ref e) = r {
        println!("{e}");
    } else {
        // Clean up temporary compilation result
        fs::remove_file(out.join("libtest.a")).expect("Failed to remove test compilation result");
    }
    r.is_ok()
}

fn conditional_define(test: &str, define: &str, command: &mut cc::Build) {
    // Pass copy of command to not modify original one
    if check_compiles(test, command.clone()) {
        command.define(define, None);
    }
}

fn main() {
    // Get build information from environment
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap();
    let use_openssl = env::var("CARGO_FEATURE_WITH_OPENSSL").is_ok();

    // Bazel's cc_wrapper appends `-U_FORTIFY_SOURCE` to $CFLAGS, which cc-rs applies
    // LAST (after this crate's `-D_FORTIFY_SOURCE=0` from `.define()`), re-enabling
    // macOS's fortify strlcat/strlcpy builtins that conflict with libpq's bundled
    // copies (`conflicting types for '__builtin___strlcat_chk'`). Re-assert
    // `-D_FORTIFY_SOURCE=0` at the very end of $CFLAGS so it has the final say.
    if target_os == "macos" {
        let cflags = env::var("CFLAGS").unwrap_or_default();
        if !cflags.contains("-D_FORTIFY_SOURCE=0") {
            env::set_var("CFLAGS", format!("{cflags} -D_FORTIFY_SOURCE=0"));
        }
    }

    println!("cargo:rerun-if-changed=additional_include");

    // === Get and define various paths ===

    // Path to pq-src (where this build.rs is located)
    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("Set by cargo");
    // Path to where this build script shall place it's output
    let out = env::var("OUT_DIR").expect("Set by cargo");

    // Path to additional includes that are shipped with pq-src
    let additional_includes_path = PathBuf::from(&crate_dir).join("additional_include");

    // Path to PostgreSQL source code
    let psql_source_path = PathBuf::from(&crate_dir).join("source");

    // Paths to relevant components within the PostgreSQL source code
    let psql_include_path = psql_source_path.join("src").join("include");
    let port_path = psql_source_path.join("src").join("port");
    let common_path = psql_source_path.join("src").join("common");
    let libpq_path = psql_source_path
        .join("src")
        .join("interfaces")
        .join("libpq");

    // For includes that are created during build time
    let temp_include = PathBuf::from(&out).join("more_include");
    if !temp_include.exists() {
        fs::create_dir(&temp_include).unwrap();
    }

    // Select port header based on target OS
    configure_os_headers(&target_os, &psql_include_path, &temp_include);

    // Collect necessary include paths
    let includes = collect_include_paths(
        &target_os,
        &port_path,
        &psql_include_path,
        &additional_includes_path,
        &temp_include,
        use_openssl,
    );

    // Create "compiler" and add previously determined includes
    let mut basic_build = cc::Build::new();
    basic_build
        .define("FRONTEND", None)
        .warnings(false)
        .includes(includes);

    if env::var("CARGO_FEATURE_WITH_ASAN").is_ok() {
        basic_build.flag("-fsanitize=address");
    }

    // Add necessary defines
    add_defines(&target_os, &target_env, use_openssl, &mut basic_build);

    // Collect files for compilation
    let (libports, libcommon, libpq) = collect_sources(&target_os, use_openssl);

    // Check if strchrnul and/or strsignal are supported, if so add defines for them
    conditional_define(TEST_FOR_STRCHRNUL, "HAVE_STRCHRNUL", &mut basic_build);
    conditional_define(TEST_FOR_STRSIGNAL, "HAVE_STRSIGNAL", &mut basic_build);

    // Compile code into statically linked library
    // Note: The compilation will output to $OUT_DIR/libpq.a
    basic_build
        .files(libports.iter().map(|f| port_path.join(f)))
        .files(libcommon.iter().map(|f| common_path.join(f)))
        .files(libpq.iter().map(|f| libpq_path.join(f)))
        .compile("pq");

    if target_os == "windows" {
        // .... and tell cargo to link against the windows system libraries
        println!("cargo:rustc-link-lib=secur32");
        println!("cargo:rustc-link-lib=shell32");
        println!("cargo:rustc-link-lib=advapi32");
    }

    // Copy over relevant headers for crates that depend on pq-sys/src
    copy_headers(
        &libpq_path,
        &psql_include_path,
        &additional_includes_path,
        &out,
    );

    // Emit metadata to set environment variables for dependants
    println!("cargo:include={out}/include");
    println!("cargo:lib_dir={out}");
}

fn configure_os_headers(target_os: &str, psql_include_path: &Path, temp_include: &Path) {
    let dest = temp_include.join("pg_config_os.h");
    if dest.exists() {
        return;
    }

    let src = match target_os {
        "linux" => psql_include_path.join("port/linux.h"),
        "macos" => psql_include_path.join("port/darwin.h"),
        "windows" => psql_include_path.join("port/win32.h"),
        _ => unimplemented(target_os, "any"),
    };

    fs::copy(src, dest).unwrap();
}

fn collect_include_paths(
    target_os: &str,
    port_path: &Path,
    psql_include_path: &Path,
    additional_includes_path: &Path,
    temp_include: &Path,
    use_openssl: bool,
) -> Vec<PathBuf> {
    // Include paths for all builds
    let mut includes = vec![
        port_path.to_path_buf(),
        psql_include_path.to_path_buf(),
        additional_includes_path.to_path_buf(),
        temp_include.to_path_buf(),
    ];

    if target_os == "windows" {
        // Add additional include paths for windows builds...
        includes.push(psql_include_path.join("port/win32"));
        includes.push(psql_include_path.join("port/win32_msvc"));
    }

    if use_openssl {
        let openssl_include = PathBuf::from(
            env::var("DEP_OPENSSL_INCLUDE")
                .expect("DEP_OPENSSL_INCLUDE must be set when using OpenSSL"),
        );
        includes.push(openssl_include);
    }

    includes
}

fn add_defines(os: &str, env: &str, use_openssl: bool, build: &mut cc::Build) {
    match os {
        "linux" => {
            build.define("_GNU_SOURCE", None);
        }
        "macos" => {
            // something is broken in homebrew
            // https://github.com/Homebrew/legacy-homebrew/pull/23620
            build.define("_FORTIFY_SOURCE", Some("0"));
        }
        "windows" => {
            build.define("WIN32", None);
            build.define("_WINDOWS", None);
            build.define("__WIN32__", None);
            build.define("__WINDOWS__", None);
            build.define("HAVE_SOCKLEN_T", Some("1"));
        }
        _ => unimplemented(os, env),
    }

    match env {
        "musl" => {
            build.define("STRERROR_R_INT", None);
            build.define("HAVE_TERMIOS_H", None);
            // This most likely is alread added by linux case above
            // but we add it here just in case it was not
            build.define("_GNU_SOURCE", None);
        }
        // Nothing to add for GNU, MSVC and MacOS
        "gnu" | "msvc" => (),
        "" if os == "macos" => (), // MacOS has no toolchain environment
        _ => unimplemented(os, env),
    }

    if use_openssl {
        // Define to 1 to build with OpenSSL support. (--with-ssl=openssl)
        build.define("USE_OPENSSL", "1");
    }
}

fn collect_sources(
    os: &str,
    use_openssl: bool,
) -> (Vec<&'static str>, Vec<&'static str>, Vec<&'static str>) {
    let ports = match os {
        "linux" => [LIBPORTS_BASE, LIBPORTS_LINUX].concat(),
        "macos" => [LIBPORTS_BASE, LIBPORTS_MACOS].concat(),
        "windows" => [LIBPORTS_BASE, LIBPORTS_WINDOWS].concat(),
        _ => unimplemented(os, "any"),
    };

    let common = match (os, use_openssl) {
        ("windows", true) => [LIBCOMMON_BASE, LIBCOMMON_OPENSSL, LIBCOMMON_WINDOWS].concat(),
        ("windows", false) => [LIBCOMMON_BASE, LIBCOMMON_NOT_OPENSSL, LIBCOMMON_WINDOWS].concat(),
        ("linux" | "macos", true) => {
            [LIBCOMMON_BASE, LIBCOMMON_OPENSSL, LIBCOMMON_NOT_WINDOWS].concat()
        }
        ("linux" | "macos", false) => {
            [LIBCOMMON_BASE, LIBCOMMON_NOT_OPENSSL, LIBCOMMON_NOT_WINDOWS].concat()
        }
        (_, _) => unimplemented(os, "any"),
    };

    let pq = match (os, use_openssl) {
        ("windows", true) => [LIBPQ_BASE, LIBPQ_OPENSSL, LIBPQ_WINDOWS].concat(),
        ("windows", false) => [LIBPQ_BASE, LIBPQ_WINDOWS].concat(),
        ("linux" | "macos", true) => [LIBPQ_BASE, LIBPQ_OPENSSL, LIBPQ_NOT_WINDOWS].concat(),
        ("linux" | "macos", false) => [LIBPQ_BASE, LIBPQ_NOT_WINDOWS].concat(),
        (_, _) => unimplemented(os, "any"),
    };

    (ports, common, pq)
}

fn copy_headers(
    libpq_path: &Path,
    psql_include_path: &Path,
    additional_includes_path: &Path,
    out: &str,
) {
    // Directory that shall hold the relevant headers for dependants
    let include_path = PathBuf::from(out).join("include");
    // Same as include_path, but for postgres internals
    let postgres_internal_path = include_path.join("postgres").join("internal");

    fs::create_dir_all(&postgres_internal_path).expect("Failed to create include directory");

    let headers_to_copy = [
        // (source_dir, filename, is_internal)
        (libpq_path, "libpq-fe.h", false),
        (libpq_path, "libpq-events.h", false),
        (psql_include_path, "postgres_ext.h", false),
        (additional_includes_path, "pg_config_ext.h", false),
        (libpq_path, "libpq-int.h", true),
        (libpq_path, "fe-auth-sasl.h", true),
        (libpq_path, "pqexpbuffer.h", true),
    ];

    for (src_dir, filename, is_internal) in headers_to_copy {
        let src = src_dir.join(filename);
        let dest = if is_internal {
            postgres_internal_path.join(filename)
        } else {
            include_path.join(filename)
        };

        fs::copy(&src, &dest).unwrap_or_else(|_| {
            panic!("Failed to copy {:?} to {:?}", src, dest);
        });
    }
}
