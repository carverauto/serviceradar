fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Generate tonic/prost stubs for the language-agnostic add-on contract that
    // every native ServiceRadar agent add-on serves over the HashiCorp go-plugin
    // transport. The agent is the go-plugin client; the add-on is the server.
    let proto_path = "proto/agent/addon/v1/addon.proto";

    tonic_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(true)
        .build_client(true)
        .disable_comments(".") // avoid doctest issues from proto comments
        .compile_protos(&[proto_path], &["proto"])?;

    println!("cargo:rerun-if-changed={proto_path}");

    Ok(())
}
