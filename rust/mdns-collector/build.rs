fn main() -> Result<(), Box<dyn std::error::Error>> {
    let proto_path = "../../proto/mdns/mdns.proto";

    tonic_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(false)
        .build_client(false)
        .compile_protos(&[proto_path], &["../../proto/mdns"])?;

    println!("cargo:rerun-if-changed={}", proto_path);

    Ok(())
}
