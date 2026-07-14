use std::{
    env, fs,
    io::Write as _,
    path::{Path, PathBuf},
};

struct Build {
    cfg: cc::Build,
    is_msvc: bool,
}

impl Build {
    fn new(cfg: cc::Build) -> Self {
        let is_msvc = cfg.try_get_compiler().unwrap().is_like_msvc();
        Self { cfg, is_msvc }
    }

    fn append(&mut self, root: Option<&str>, files: &[&str]) {
        let root = root.map_or(String::new(), |s| {
            assert!(!s.ends_with('/'), "remove trailing slash");
            format!("{s}/")
        });
        self.cfg.files(
            files
                .into_iter()
                .map(|fname| format!("src/zlib-ng/{root}{fname}.c")),
        );
    }

    fn mflag(
        &mut self,
        non_msvc: impl Into<Option<&'static str>>,
        msvc: impl Into<Option<&'static str>>,
    ) {
        let Some(flag) = (if self.is_msvc {
            msvc.into()
        } else {
            non_msvc.into()
        }) else {
            return;
        };
        self.cfg.flag(flag);
    }
}

impl std::ops::Deref for Build {
    type Target = cc::Build;

    fn deref(&self) -> &Self::Target {
        &self.cfg
    }
}

impl std::ops::DerefMut for Build {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.cfg
    }
}

/// Replicate the behavior of cmake/make/configure of stripping out the
/// @ZLIB_SYMBOL_PREFIX@ since we don't want or need it
fn strip_symbol_prefix(input: &Path, output: &Path, get_version: bool) -> String {
    let contents = fs::read_to_string(input)
        .map_err(|err| format!("failed to read {input:?}: {err}"))
        .unwrap();
    let mut h =
        std::io::BufWriter::new(fs::File::create(output).expect("failed to create zlib include"));

    use std::io::IoSlice;
    let mut write = |bufs: &[IoSlice]| {
        // write_all_vectored is unstable
        for buf in bufs {
            h.write_all(&buf).unwrap();
        }
    };

    let mut version = None;
    for line in contents.lines() {
        if let Some((begin, end)) = line.split_once("@ZLIB_SYMBOL_PREFIX@") {
            write(&[
                IoSlice::new(begin.as_bytes()),
                IoSlice::new(end.as_bytes()),
                IoSlice::new(b"\n"),
            ]);
        } else {
            write(&[IoSlice::new(line.as_bytes()), IoSlice::new(b"\n")]);
        }

        if get_version {
            if line.contains("ZLIBNG_VERSION") && line.contains("#define") {
                version = Some(line.split('"').nth(1).unwrap().to_owned());
            }
        }
    }

    if get_version {
        version.expect("failed to detect ZLIBNG_VERSION")
    } else {
        String::new()
    }
}
pub fn build_zlib_ng(target: &str, compat: bool) {
    let mut cfg = cc::Build::new();

    let dst = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let lib = dst.join("lib");
    cfg.warnings(false).out_dir(&lib);

    let mut cfg = Build::new(cfg);

    cfg.append(
        None,
        &[
            "adler32",
            "compress",
            "cpu_features",
            "crc32",
            "crc32_braid_comb",
            "deflate",
            "deflate_fast",
            "deflate_huff",
            "deflate_medium",
            "deflate_quick",
            "deflate_rle",
            "deflate_slow",
            "deflate_stored",
            "functable",
            // GZFILEOP
            "gzlib",
            "gzwrite",
            "infback",
            "inflate",
            "inftrees",
            "insert_string",
            "insert_string_roll",
            "trees",
            "uncompr",
            "zutil",
        ],
    );

    cfg.append(
        Some("arch/generic"),
        &[
            "adler32_c",
            "adler32_fold_c",
            "chunkset_c",
            "compare256_c",
            "crc32_braid_c",
            "crc32_fold_c",
            "slide_hash_c",
        ],
    );

    if compat {
        cfg.define("ZLIB_COMPAT", None);
    }

    cfg.define("WITH_GZFILEOP", None);

    {
        let mut build = dst.join("build");
        fs::create_dir_all(&build).unwrap();
        build.push("gzread.c");

        strip_symbol_prefix(Path::new("src/zlib-ng/gzread_mangle.h.in"), &build, false);
        cfg.file(build);
    }

    let msvc = target.ends_with("pc-windows-msvc");

    cfg.std("c11");

    // This can be made configurable if it is an issue but most of these would
    // only fail if the user was on a decade old+ libc impl
    if !msvc {
        cfg.define("HAVE_ALIGNED_ALLOC", None)
            .define("HAVE_ATTRIBUTE_ALIGNED", None)
            .define("HAVE_BUILTIN_CTZ", None)
            .define("HAVE_BUILTIN_CTZLL", None)
            .define("HAVE_THREAD_LOCAL", None)
            .define("HAVE_VISIBILITY_HIDDEN", None)
            .define("HAVE_VISIBILITY_INTERNAL", None)
            .define("_LARGEFILE64_SOURCE", "1")
            .define("__USE_LARGEFILE64", None);

        // Turn implicit functions into errors, this would indicate eg. a
        // define is not set
        cfg.flag("-Werror-implicit-function-declaration");
    }

    if !target.contains("windows") {
        cfg.define("STDC", None)
            .define("_POSIX_SOURCE", None)
            .define("HAVE_POSIX_MEMALIGN", None)
            .flag("-fvisibility=hidden");
    }

    let is_apple = target.contains("apple");
    if is_apple {
        cfg.define("_C99_SOURCE", None);
    } else if target.contains("solaris") {
        cfg.define("_XOPEN_SOURCE", "700");
    }

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let arch = env::var("CARGO_CFG_TARGET_ARCH").expect("failed to retrieve target arch");
    let features = env::var("CARGO_CFG_TARGET_FEATURE").unwrap();

    let is_linux_or_android = matches!(target_os.as_str(), "linux" | "android");
    if is_linux_or_android {
        cfg.define("HAVE_SYS_AUXV_H", None);
    }

    match arch.as_str() {
        "x86_64" | "i686" => {
            cfg.define("X86_FEATURES", None);
            cfg.file("src/zlib-ng/arch/x86/x86_features.c");

            let is_64 = arch.as_str() == "x86_64";

            // AVX2
            cfg.define("X86_AVX2", None);
            cfg.append(
                Some("arch/x86"),
                &[
                    "chunkset_avx2",
                    "compare256_avx2",
                    "adler32_avx2",
                    "slide_hash_avx2",
                ],
            );
            cfg.mflag("-mavx2", "/arch:AVX2");

            // SSE2
            cfg.define("X86_SSE2", None);
            cfg.append(
                Some("arch/x86"),
                &["chunkset_sse2", "compare256_sse2", "slide_hash_sse2"],
            );
            cfg.mflag("-msse2", (!is_64).then_some("/arch:SSE2"));

            // SSE3
            cfg.define("X86_SSSE3", None);
            cfg.append(Some("arch/x86"), &["adler32_ssse3", "chunkset_ssse3"]);
            cfg.mflag("-msse3", "/arch:SSE3");

            // SSE4.2
            cfg.define("X86_SSE42", None);
            cfg.append(Some("arch/x86"), &["adler32_sse42"]);
            cfg.mflag("-msse4.2", "/arch:SSE4.2");

            // AVX-512
            {
                for def in &[
                    "X86_AVX512",
                    "X86_MASK_INTRIN",
                    "X86_AVX512VNNI",
                    "X86_VPCLMULQDQ_CRC",
                ] {
                    cfg.define(def, None);
                }

                cfg.append(
                    Some("arch/x86"),
                    &["adler32_avx512", "adler32_avx512_vnni", "crc32_vpclmulqdq"],
                );

                if cfg.is_msvc {
                    cfg.flag("/arch:AVX512");
                } else {
                    // The zlib-ng cmake scripts to check target features claim that GCC doesn't
                    // generate good code unless mtune is set, not sure if this is still the
                    // case, but we faithfully replicate it just in case
                    for flag in &[
                        "-mavx512f",
                        "-mavx512dq",
                        "-mavx512bw",
                        "-mavx512vl",
                        "-mavx512vnni",
                        "-mvpclmulqdq",
                        "-mtune=cascadelake",
                    ] {
                        cfg.flag(flag);
                    }
                }
            }

            // Misc
            cfg.define("X86_PCLMULQDQ_CRC", None);
            cfg.append(Some("arch/x86"), &["crc32_pclmulqdq"]);
            cfg.mflag("-mpclmul", None);
            cfg.mflag("-mxsave", None);
        }
        "aarch64" | "arm" => {
            let is_aarch64 = arch == "aarch64";

            cfg.define("ARM_FEATURES", None);
            cfg.file("src/zlib-ng/arch/arm/arm_features.c");

            // Support runtime detection on linux/android
            if is_linux_or_android {
                cfg.define("ARM_AUXV_HAS_CRC32", None);

                if !is_aarch64 {
                    cfg.define("ARM_AUXV_HAS_NEON", None);
                }
            }

            // According to the cmake macro, MSVC is missing the crc32 intrinsic
            // for arm, don't know if that is still true though
            if !cfg.is_msvc || is_aarch64 {
                cfg.define("ARM_ACLE", None).define("HAVE_ARM_ACLE_H", None);
                cfg.append(Some("arch/arm"), &["crc32_armv8"]);
                // When targeting aarch64 we already need to specify +simd, so
                // we do that once later in this block
                if !is_aarch64 {
                    cfg.mflag("-march=armv8-a+crc", None);
                    cfg.define("ARM_ASM_HWCAP", None);
                }
            }

            // neon
            // Fix armv7-unknown-linux-musleabi and arm-unknown-linux-musleabi by only
            // passing in ARM_NEON if that target is enabled.
            // Disable for apple targets due to https://github.com/rust-lang/libz-sys/issues/230
            if !is_apple && features.split(",").any(|name| name == "neon") {
                cfg.define("ARM_NEON", None);
            }

            // NOTE: These intrinsics were only added in gcc 9.4, which is _relatively_
            // recent, and if the define is not set zlib-ng just provides its
            // own implements, so maybe in a couple of years this can be toggled on
            // if building with cc is merged it makes sense to put compiler intrinsic/header
            // probing in a separate crate that can then be used here to enable
            // those intrinsics if the compiler supports them
            // * vld1q_u16_x4
            // * vld1q_u8_x4
            // * vst1q_u16_x4
            // cfg.define("ARM_NEON_HASLD4", None)

            if cfg.is_msvc {
                cfg.define("__ARM_NEON__", None);
            }
            cfg.append(
                Some("arch/arm"),
                &[
                    "adler32_neon",
                    "chunkset_neon",
                    "compare256_neon",
                    "slide_hash_neon",
                ],
            );
            cfg.mflag(
                if is_aarch64 {
                    "-march=armv8-a+crc+simd"
                } else {
                    "-mfpu=neon"
                },
                None,
            );
        }
        "s390x" => {
            for def in &[
                "S390_FEATURES",
                "S390_DFLTCC_DEFLATE",
                "S390_DFLTCC_INFLATE",
                "S390_CRC32_VX",
            ] {
                cfg.define(def, None);
            }
            cfg.flag("-DDFLTCC_LEVEL_MASK=0x7e");

            cfg.append(
                Some("arch/s390"),
                &[
                    "crc32-vx",
                    "dfltcc_common",
                    "dfltcc_deflate",
                    "dfltcc_inflate",
                    "s390_features",
                ],
            );
        }
        _ => {
            // NOTE: PowerPC and Riscv
            // zlib-ng can use intrinsics for both of these targets, however neither
            // of them are currently checked in CI, they will still work without
            // using the intrinsics, they will just be slower
            // PowerPC - <github issue here>
            // Riscv - <github issue here>
        }
    }

    let include = dst.join("include");

    fs::create_dir_all(&include).unwrap();

    let (zconf_h, zlib_h, mangle) = if compat {
        ("zconf.h", "zlib.h", "zlib_name_mangling.h")
    } else {
        fs::copy("src/zlib-ng/zconf-ng.h.in", include.join("zconf-ng.h")).unwrap();
        ("zconf-ng.h", "zlib-ng.h", "zlib_name_mangling-ng.h")
    };

    if msvc {
        fs::copy(format!("src/zlib-ng/{zconf_h}.in"), include.join(zconf_h)).unwrap();
    } else {
        // If we don't do this then _some_ 32-bit targets will have an incorrect
        // size for off_t if they don't _also_ define `HAVE_UNISTD_H`, so we
        // copy configure/cmake here
        let new_zconf = fs::read_to_string(format!("src/zlib-ng/{zconf_h}.in"))
            .expect("failed to read zconf.h.in")
            .replace(
                "#ifdef HAVE_UNISTD_H    /* may be set to #if 1 by configure/cmake/etc */",
                &format!(
                    "#if 1    /* was set to #if 1 by {}:{}:{} */",
                    file!(),
                    line!(),
                    column!()
                ),
            );

        fs::write(include.join(zconf_h), new_zconf).unwrap();
    }

    fs::copy(
        "src/zlib-ng/zlib_name_mangling.h.empty",
        include.join(mangle),
    )
    .unwrap();

    let version = strip_symbol_prefix(
        Path::new(&format!("src/zlib-ng/{zlib_h}.in")),
        &include.join(zlib_h),
        true,
    );

    cfg.include(&include).include("src/zlib-ng");
    if let Err(err) = cfg.try_compile("z") {
        let version = if !cfg.is_msvc {
            match std::process::Command::new(cfg.get_compiler().path())
                .arg("--version")
                .output()
            {
                Ok(output) => String::from_utf8_lossy(&output.stdout).into_owned(),
                Err(_err) => "unknown".into(),
            }
        } else {
            "msvc".into()
        };

        eprintln!("{err}");
        panic!(
            "failed to compile zlib-ng with cc: detected compiler version as \n---\n{}---",
            version
        );
    }

    fs::create_dir_all(lib.join("pkgconfig")).unwrap();
    fs::write(
        lib.join("pkgconfig/zlib.pc"),
        fs::read_to_string("src/zlib-ng/zlib.pc.in")
            .unwrap()
            .replace("@prefix@", dst.to_str().unwrap())
            .replace("@includedir@", "${prefix}/include")
            .replace("@libdir@", "${prefix}/lib")
            .replace("@VERSION@", &version),
    )
    .unwrap();

    println!("cargo:root={}", dst.display());
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:include={}", include.display());

    if !compat {
        println!("cargo:rustc-cfg=zng");
    }
}

#[allow(dead_code)]
fn main() {
    let target = env::var("TARGET").unwrap();
    build_zlib_ng(&target, false);
}
