fn main() {
    let schema = "../../../../arancini/arancini/schemas/update.capnp";
    let schema_root = "../../../../arancini/arancini/schemas";
    println!("cargo:rerun-if-changed={schema}");

    capnpc::CompilerCommand::new()
        .src_prefix(schema_root)
        .import_path(schema_root)
        .file(schema)
        .run()
        .expect("failed to compile Cap'n Proto schema");
}
