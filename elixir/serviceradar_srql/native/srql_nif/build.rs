fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set by Cargo");
    let schema_root = std::path::Path::new(&manifest_dir).join("schemas");
    let schema = schema_root.join("update.capnp");
    println!("cargo:rerun-if-changed={}", schema.display());

    capnpc::CompilerCommand::new()
        .src_prefix(&schema_root)
        .import_path(&schema_root)
        .file(schema)
        .run()
        .expect("failed to compile Cap'n Proto schema");
}
