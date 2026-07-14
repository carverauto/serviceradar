use std::env;

pub fn build_zlib_ng(target: &str, compat: bool) {
    let mut cmake = cmake::Config::new("src/zlib-ng");
    cmake
        .define("BUILD_SHARED_LIBS", "OFF")
        .define("ZLIB_COMPAT", if compat { "ON" } else { "OFF" })
        .define("ZLIB_ENABLE_TESTS", "OFF")
        .define("WITH_GZFILEOP", "ON");
    if target.contains("s390x") {
        // Enable hardware compression on s390x.
        cmake
            .define("WITH_DFLTCC_DEFLATE", "1")
            .define("WITH_DFLTCC_INFLATE", "1")
            .cflag("-DDFLTCC_LEVEL_MASK=0x7e");
    }
    if target.contains("riscv") {
        // Check if we should pass on an explicit boolean value of the WITH_RVV build option.
        // See: https://github.com/zlib-ng/zlib-ng?tab=readme-ov-file#advanced-build-options
        if let Ok(value) = env::var("RISCV_WITH_RVV") {
            match value.trim().to_uppercase().as_str() {
                "OFF" | "NO" | "FALSE" | "0" => {
                    // Force RVV off. This turns off RVV entirely, as well as the runtime check for it.
                    // This is not usually necessary, but can be useful for building binaries portable
                    // to systems that do not support RVV but where auto-detection fails to identify
                    // this (as in https://github.com/zlib-ng/zlib-ng/issues/1705).
                    cmake.define("WITH_RVV", "OFF");
                }
                "ON" | "YES" | "TRUE" | "1" => {
                    // Try to use RVV, but still don't do so if a runtime check finds it unavailable.
                    // This has the same effect as omitting WITH_RVV, unless it has already been set.
                    cmake.define("WITH_RVV", "ON");
                }
                _ => {}
            }
        }
    }
    if target == "i686-pc-windows-msvc" {
        cmake.define("CMAKE_GENERATOR_PLATFORM", "Win32");
    }

    // libz-ng uses the GNUInstallDirs convention, so we can use the following
    // to ensure libraries are placed in a consistent place in the
    // installation dir.
    cmake.define("CMAKE_INSTALL_LIBDIR", "lib");

    let install_dir = cmake.build();

    let includedir = install_dir.join("include");
    let libdir = install_dir.join("lib");
    println!(
        "cargo:rustc-link-search=native={}",
        libdir.to_str().unwrap()
    );
    let mut debug_suffix = "";
    let libname = if target.contains("windows") && target.contains("msvc") {
        if env::var("OPT_LEVEL").unwrap() == "0" {
            debug_suffix = "d";
        }
        "zlibstatic"
    } else {
        "z"
    };
    println!(
        "cargo:rustc-link-lib=static={}{}{}",
        libname,
        if compat { "" } else { "-ng" },
        debug_suffix,
    );
    println!("cargo:root={}", install_dir.to_str().unwrap());
    println!("cargo:include={}", includedir.to_str().unwrap());
    if !compat {
        println!("cargo:rustc-cfg=zng");
    }
}

#[allow(dead_code)]
fn main() {
    let target = env::var("TARGET").unwrap();
    build_zlib_ng(&target, false);
}
