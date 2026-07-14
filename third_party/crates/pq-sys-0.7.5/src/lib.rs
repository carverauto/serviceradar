#[cfg(any(feature = "bundled", feature = "bundled_without_openssl"))]
extern crate pq_src;

#[allow(non_camel_case_types, non_upper_case_globals, non_snake_case)]
mod bindings {
    #[cfg(buildscript_run)]
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

#[cfg(not(buildscript_run))]
compile_error!(
    "pq-sys relies on build scripts beeing executed. \n \
     Please double check that you don't have a `[target.*.pq]` entry \
     in your `.cargo/config.toml`\n \
     These entries prevent build scripts from beeing run"
);

pub use bindings::*;

#[cfg(not(feature = "buildtime_bindgen"))]
#[test]
fn check_generated_bindings_match() {
    let libpq_include_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/pq-src/source/src/interfaces/libpq/"
    );
    let postgres_include_path = concat!(env!("CARGO_MANIFEST_DIR"), "/pq-src/source/src/include");
    let additional_includes_path =
        concat!(env!("CARGO_MANIFEST_DIR"), "/pq-src/additional_include/");

    let builder = include!("make_bindings.rs").clang_args([
        "-I",
        libpq_include_path,
        "-I",
        postgres_include_path,
        "-I",
        additional_includes_path,
    ]);

    let generated_bindings = builder.generate().expect("Unable to generate bindings");

    let mut out = Vec::<u8>::new();
    generated_bindings.write(Box::new(&mut out)).unwrap();
    let generated_bindings = String::from_utf8(out).unwrap();

    let bundled_bindings =
        std::fs::read_to_string(String::from(env!("OUT_DIR")) + "/bindings.rs").unwrap();
    similar_asserts::assert_eq!(generated_bindings, bundled_bindings,)
}
