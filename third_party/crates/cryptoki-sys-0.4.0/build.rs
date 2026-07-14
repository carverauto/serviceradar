// Copyright 2021,2023 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
fn main() {
    #[cfg(feature = "generate-bindings")]
    {
        generate::generate_bindings();
    }
}

// Only on a specific feature
#[cfg(feature = "generate-bindings")]
mod generate {
    use bindgen::callbacks;
    #[derive(Debug)]
    pub struct CargoCallbacks;

    impl callbacks::ParseCallbacks for CargoCallbacks {
        // skip processing CK_UNAVAILABLE_INFORMATION macro, more details in lib.rs
        fn will_parse_macro(&self, name: &str) -> callbacks::MacroParsingBehavior {
            if name == "CK_UNAVAILABLE_INFORMATION" {
                callbacks::MacroParsingBehavior::Ignore
            } else {
                callbacks::MacroParsingBehavior::Default
            }
        }

        fn int_macro(&self, name: &str, _: i64) -> Option<callbacks::IntKind> {
            let prefixes = [
                ("CK_", "CK_ULONG"),
                ("CKA_", "CK_ATTRIBUTE_TYPE"),
                ("CKC_", "CK_CERTIFICATE_TYPE"),
                ("CKD_", "CK_EC_KDF_TYPE"),
                ("CKF_", "CK_FLAGS"),
                ("CKG_MGF1_", "CK_RSA_PKCS_MGF_TYPE"),
                ("CKG", "CK_GENERATOR_FUNCTION"),
                ("CKH_", "CK_HW_FEATURE_TYPE"),
                ("CKK_", "CK_KEY_TYPE"),
                ("CKM_", "CK_MECHANISM_TYPE"),
                ("CKN_", "CK_NOTIFICATION"),
                ("CKO_", "CK_OBJECT_CLASS"),
                (
                    "CKP_PKCS5_PBKD2_",
                    "CK_PKCS5_PBKD2_PSEUDO_RANDOM_FUNCTION_TYPE",
                ),
                ("CKP_", "CK_PROFILE_ID"),
                ("CKR_", "CK_RV"),
                ("CKS_", "CK_STATE"),
                ("CKU_", "CK_USER_TYPE"),
                ("CKZ_DATA_SPECIFIED", "CK_RSA_PKCS_OAEP_SOURCE_TYPE"),
                ("CKZ_SALT_SPECIFIED", "CK_PKCS5_PBKDF2_SALT_SOURCE_TYPE"),
                ("CRYPTOKI_VERSION_", "CK_BYTE"),
            ];

            if ["CK_TRUE", "CK_FALSE"].contains(&name) {
                Some(callbacks::IntKind::Custom {
                    name: "CK_BBOOL",
                    is_signed: false,
                })
            } else {
                let mut result = None;
                for (prefix, variable) in &prefixes {
                    if name.starts_with(prefix) {
                        result = Some(callbacks::IntKind::Custom {
                            name: variable,
                            is_signed: false,
                        })
                    }
                }
                result
            }
        }
    }

    pub fn generate_bindings() {
        let make_generic: bool = std::env::var_os("MAKE_GENERIC_BINDINGS").is_some();
        let mut builder = bindgen::Builder::default();
        // to be fully compatible with 2.4
        builder = builder.header_contents("enable-deprecated.h", "#define PKCS11_DEPRECATED 1\n");
        if make_generic {
            // only WIN32 bindings are "packed". It's easier to "unpack" for other architectures
            // __declspec is not needed and causes problems
            const GENERIC_PRELUDE: &str = "#define _WIN32 1\n#define __declspec(x)\n";
            builder = builder
                // layout tests are not generic
                .layout_tests(false)
                .header_contents("generic-prelude.h", GENERIC_PRELUDE)
        }

        builder = builder
            .header("vendor/pkcs11.h")
            .dynamic_library_name("Pkcs11")
            // The PKCS11 library works in a slightly different way to most shared libraries. We have
            // to call `C_GetFunctionList`, which returns a list of pointers to the _actual_ library
            // functions (in PKCS #11 before 3.0). The PKCS #11 3.0 introduces the new functions
            // `C_GetInterface` and `C_GetInterfaceList` to request the hew functions from 3.0 API.
            // These are the only function we need to create a binding for.
            .allowlist_function("C_GetFunctionList")
            .allowlist_function("C_GetInterfaceList")
            .allowlist_function("C_GetInterface")
            // This is needed because no types will be generated if `allowlist_function` is used.
            // Unsure if this is a bug.
            .allowlist_type("*")
            .allowlist_file("vendor/pkcs11.h")
            // See this issue: https://github.com/parallaxsecond/rust-cryptoki/issues/12
            .blocklist_type("max_align_t")
            // Derive the `Debug` trait for the generated structs where possible.
            .derive_debug(true)
            // Derive the `Default` trait for the generated structs where possible.
            .derive_default(true)
            .parse_callbacks(Box::new(CargoCallbacks))
            // Support function like macros
            // https://github.com/parallaxsecond/rust-cryptoki/issues/240
            .clang_macro_fallback();

        let bindings = builder.generate().expect("Unable to generate bindings");

        let mut data = bindings.to_string();
        if make_generic {
            const PACK_ALWAYS: &str = "#[repr(C, packed)]";
            const PACK_WINDOWS: &str = "#[repr(C)]\n#[cfg_attr(windows, repr(packed))]";
            data = data.replace(PACK_ALWAYS, PACK_WINDOWS);
        }

        // Write the bindings to the $OUT_DIR/pkcs11_bindings.rs file.
        let out_path = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
        std::fs::write(out_path.join("pkcs11_bindings.rs"), data)
            .expect("Couldn't write bindings!");
    }
}
