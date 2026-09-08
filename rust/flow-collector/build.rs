fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Compile flowpb protobuf
    // Bazel path first (cwd = execroot, via the build script's symlink-exec-root feature),
    // Cargo path second (cwd = this crate dir).
    let (proto_path, proto_root) = if std::path::Path::new("proto/flow/flow.proto").exists() {
        ("proto/flow/flow.proto", "proto/flow")
    } else {
        ("../../proto/flow/flow.proto", "../../proto/flow")
    };

    tonic_prost_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(false)
        .build_client(false)
        .compile_protos(&[proto_path], &[proto_root])?;

    println!("cargo:rerun-if-changed={}", proto_path);

    Ok(())
}
