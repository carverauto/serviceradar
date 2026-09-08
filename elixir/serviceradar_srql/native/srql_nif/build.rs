fn main() {
    use std::path::PathBuf;
    use std::process::Command;

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set by Cargo");
    let schema_root = std::path::Path::new(&manifest_dir).join("schemas");
    let schema = schema_root.join("update.capnp");
    let vendored = schema_root.join("update_capnp.rs");
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR must be set by Cargo"));
    let generated = out_dir.join("update_capnp.rs");

    println!("cargo:rerun-if-changed={}", schema.display());
    println!("cargo:rerun-if-changed={}", vendored.display());

    let capnp_available = Command::new("capnp")
        .arg("--version")
        .status()
        .map(|status| status.success())
        .unwrap_or(false);

    if capnp_available {
        capnpc::CompilerCommand::new()
            .src_prefix(&schema_root)
            .import_path(&schema_root)
            .file(&schema)
            .run()
            .expect("failed to compile Cap'n Proto schema");
        return;
    }

    std::fs::copy(&vendored, &generated).unwrap_or_else(|err| {
        panic!(
            "capnp executable is unavailable and fallback file copy failed: {} -> {} ({err})",
            vendored.display(),
            generated.display()
        )
    });
}
