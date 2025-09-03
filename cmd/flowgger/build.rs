fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Compile KV proto for client usage
    let kv_proto_path = if std::path::Path::new("proto/kv.proto").exists() {
        "proto/kv.proto"
    } else {
        "../../proto/kv.proto"
    };
    let kv_proto_dir = std::path::Path::new(kv_proto_path).parent().unwrap();
    tonic_build::configure()
        .build_server(false)
        .build_client(true)
        .compile_protos(&[kv_proto_path], &[kv_proto_dir])?;
    Ok(())
}

