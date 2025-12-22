fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Compile flowpb protobuf
    let proto_path = "../../proto/flow/flow.proto";

    tonic_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(false)
        .build_client(false)
        .compile(&[proto_path], &["../../proto/flow"])?;

    println!("cargo:rerun-if-changed={}", proto_path);

    Ok(())
}
