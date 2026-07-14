use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=LIBZ_SYS_STATIC");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=zng/cmake.rs");
    println!("cargo:rerun-if-changed=zng/cc.rs");

    let host = env::var("HOST").unwrap();
    let target = env::var("TARGET").unwrap();

    let host_and_target_contain = |s| host.contains(s) && target.contains(s);

    let want_ng = cfg!(any(
        feature = "zlib-ng",
        feature = "zlib-ng-no-cmake-experimental-community-maintained"
    )) && !cfg!(feature = "stock-zlib");

    if want_ng && target != "wasm32-unknown-unknown" {
        return build_zlib_ng(&target, true);
    }

    // All android compilers should come with libz by default, so let's just use
    // the one already there. Likewise, Haiku and OpenHarmony always ship with libz,
    // so we can link to it even when cross-compiling.
    if target.contains("android") || target.contains("haiku") || target.ends_with("-ohos") {
        println!("cargo:rustc-link-lib=z");
        return;
    }

    let want_static = should_link_static();
    // Don't run pkg-config if we're linking statically (we'll build below) and
    // also don't run pkg-config on FreeBSD/DragonFly. That'll end up printing
    // `-L /usr/lib` which wreaks havoc with linking to an OpenSSL in /usr/local/lib
    // (Ports, etc.)
    if !(want_static
        // pkg-config just never works here
        || target.contains("msvc")
        || host_and_target_contain("freebsd")
        || host_and_target_contain("dragonfly"))
    {
        // Don't print system lib dirs to cargo since this interferes with other
        // packages adding non-system search paths to link against libraries
        // that are also found in a system-wide lib dir.
        let zlib = pkg_config::Config::new()
            .cargo_metadata(true)
            .print_system_libs(false)
            .probe("zlib");
        match zlib {
            Ok(zlib) => {
                if !zlib.include_paths.is_empty() {
                    let paths = zlib
                        .include_paths
                        .iter()
                        .map(|s| s.display().to_string())
                        .collect::<Vec<_>>();
                    println!("cargo:include={}", paths.join(","));
                }
            }
            Err(e) => {
                println!(
                    "cargo:warning=Could not find zlib include paths via pkg-config: {}",
                    e
                )
            }
        }
    }

    if target.contains("windows") && try_vcpkg() {
        return;
    }

    let mut cfg = cc::Build::new();

    // Situations where we build unconditionally.
    //
    // - MSVC basically never has zlib preinstalled
    // - MinGW picks up a bunch of weird paths we don't like
    // - Explicit opt-in via `want_static`
    if target.contains("msvc") || target.contains("pc-windows-gnu") || want_static {
        return build_zlib(&mut cfg, &target);
    }

    // If we've gotten this far we're probably a pretty standard platform.
    // Almost all platforms here ship libz by default, but some don't have
    // pkg-config files that we would find above.
    //
    // In any case test if zlib is actually installed and if so we link to it,
    // otherwise continue below to build things.
    if zlib_installed(&mut cfg) {
        println!("cargo:rustc-link-lib=z");
        return;
    }

    // For convenience fallback to building zlib if attempting to link zlib failed
    build_zlib(&mut cfg, &target)
}

fn build_zlib(cfg: &mut cc::Build, target: &str) {
    let dst = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let lib = dst.join("lib");

    cfg.warnings(false).out_dir(&lib).include("src/zlib");

    cfg.file("src/zlib/adler32.c")
        .file("src/zlib/compress.c")
        .file("src/zlib/crc32.c")
        .file("src/zlib/deflate.c")
        .file("src/zlib/infback.c")
        .file("src/zlib/inffast.c")
        .file("src/zlib/inflate.c")
        .file("src/zlib/inftrees.c")
        .file("src/zlib/trees.c")
        .file("src/zlib/uncompr.c")
        .file("src/zlib/zutil.c");

    if target.starts_with("wasm32") {
        cfg.define("Z_SOLO", None);
        // zlib 1.3.2 uses `NULL` directly in compress.c/uncompr.c, but the
        // Z_SOLO config path doesn't pull in headers that always define it.
        cfg.define("NULL", Some("0"));
    } else {
        cfg.file("src/zlib/gzclose.c")
            .file("src/zlib/gzlib.c")
            .file("src/zlib/gzread.c")
            .file("src/zlib/gzwrite.c");
    }

    // zlib's zconf.h gates standard headers on `STDC` (not `__STDC__`), and
    // 1.3.2 uses `NULL` directly in compress.c/uncompr.c.
    cfg.define("STDC", None);

    if !target.contains("windows") {
        cfg.define("_LARGEFILE64_SOURCE", None);
        cfg.flag("-fvisibility=hidden");
    }

    cfg.compile("z");

    fs::create_dir_all(dst.join("include")).unwrap();
    fs::copy("src/zlib/zlib.h", dst.join("include/zlib.h")).unwrap();
    fs::copy("src/zlib/zconf.h", dst.join("include/zconf.h")).unwrap();

    fs::create_dir_all(lib.join("pkgconfig")).unwrap();
    let zlib_h = fs::read_to_string(dst.join("include/zlib.h")).unwrap();
    let version = zlib_h
        .lines()
        .find(|l| l.contains("ZLIB_VERSION"))
        .unwrap()
        .split("\"")
        .nth(1)
        .unwrap();
    fs::write(
        lib.join("pkgconfig/zlib.pc"),
        fs::read_to_string("src/zlib/zlib.pc.in")
            .unwrap()
            .replace("@prefix@", dst.to_str().unwrap())
            .replace("@includedir@", "${prefix}/include")
            .replace("@libdir@", "${prefix}/lib")
            .replace("@VERSION@", version),
    )
    .unwrap();

    println!("cargo:root={}", dst.to_str().unwrap());
    println!("cargo:rustc-link-search=native={}", lib.to_str().unwrap());
    println!("cargo:include={}/include", dst.to_str().unwrap());
}

#[cfg(any(
    feature = "zlib-ng",
    feature = "zlib-ng-no-cmake-experimental-community-maintained"
))]
mod zng {
    #[cfg_attr(feature = "zlib-ng", path = "cmake.rs")]
    #[cfg_attr(
        all(
            feature = "zlib-ng-no-cmake-experimental-community-maintained",
            not(feature = "zlib-ng")
        ),
        path = "cc.rs"
    )]
    mod build_zng;

    pub(super) use build_zng::build_zlib_ng;
}

fn build_zlib_ng(_target: &str, _compat: bool) {
    #[cfg(any(
        feature = "zlib-ng",
        feature = "zlib-ng-no-cmake-experimental-community-maintained"
    ))]
    zng::build_zlib_ng(_target, _compat);
}

fn try_vcpkg() -> bool {
    // see if there is a vcpkg tree with zlib installed
    match vcpkg::Config::new()
        .emit_includes(true)
        .find_package("zlib")
    {
        Ok(zlib) => {
            if !zlib.include_paths.is_empty() {
                let paths = zlib
                    .include_paths
                    .iter()
                    .map(|s| s.display().to_string())
                    .collect::<Vec<_>>();
                println!("cargo:include={}", paths.join(","));
            }
            true
        }
        Err(e) => {
            println!("note, vcpkg did not find zlib: {}", e);
            false
        }
    }
}

fn zlib_installed(cfg: &mut cc::Build) -> bool {
    let mut cmd = cfg.get_compiler().to_command();
    cmd.arg("src/smoke.c")
        .arg("-g0")
        .arg("-o")
        .arg("/dev/null")
        .arg("-lz");

    println!("running {:?}", cmd);
    if let Ok(status) = cmd.status() {
        if status.success() {
            return true;
        }
    }

    false
}

/// The environment variable `LIBZ_SYS_STATIC` is first checked for a value of `0` (false) or `1` (true),
/// before considering the `static` feature when no explicit ENV value was detected.
/// When `libz-sys` is a transitive dependency from a crate that forces static linking via the `static` feature,
/// this enables the build environment to revert that preference via `LIBZ_SYS_STATIC=0`.
/// The default is otherwise `false`.
fn should_link_static() -> bool {
    let has_static_env: Option<&'static str> = option_env!("LIBZ_SYS_STATIC");
    let has_static_cfg = cfg!(feature = "static");

    has_static_env
        .and_then(|s: &str| s.parse::<u8>().ok())
        .and_then(|b| match b {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        })
        .unwrap_or(has_static_cfg)
}
