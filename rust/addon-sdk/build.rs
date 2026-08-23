fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Generate tonic/prost stubs for the language-agnostic add-on contract that
    // every native ServiceRadar agent add-on serves over the HashiCorp go-plugin
    // transport. The agent is the go-plugin client; the add-on is the server.
    let addon_proto_path = "proto/agent/addon/v1/addon.proto";
    // The discovery envelope an add-on wraps device observations in. Compiled
    // here rather than per add-on so every add-on gets the same contract, and
    // so `discovery_record` below can build one.
    let discovery_proto_path = "proto/agent/discovery/v1/discovery.proto";

    tonic_prost_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(true)
        .build_client(true)
        .disable_comments(["."]) // avoid doctest issues from proto comments
        .compile_protos(&[addon_proto_path, discovery_proto_path], &["proto"])?;

    println!("cargo:rerun-if-changed={addon_proto_path}");
    println!("cargo:rerun-if-changed={discovery_proto_path}");

    Ok(())
}
