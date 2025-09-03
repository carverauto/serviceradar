fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .disable_comments(".") // Disable comments to avoid doctest issues
        .compile_protos(
            &[
                "proto/opentelemetry/proto/collector/trace/v1/trace_service.proto",
                "proto/opentelemetry/proto/collector/logs/v1/logs_service.proto",
                "proto/opentelemetry/proto/trace/v1/trace.proto",
                "proto/opentelemetry/proto/logs/v1/logs.proto",
                "proto/opentelemetry/proto/resource/v1/resource.proto",
                "proto/opentelemetry/proto/common/v1/common.proto",
            ],
            &["proto"],
        )?;
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
