fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Bazel path first (cwd = execroot, via the build script's symlink-exec-root feature),
    // Cargo path second (cwd = this crate dir).
    let metric_proto_path = if std::path::Path::new("proto/metric/v1/metric.proto").exists() {
        "proto/metric/v1/metric.proto"
    } else {
        "../../proto/metric/v1/metric.proto"
    };
    let metric_proto_root = if metric_proto_path.starts_with("..") {
        "../../proto"
    } else {
        "proto"
    };

    tonic_prost_build::configure()
        .build_server(false)
        .build_client(false)
        .disable_comments(["."])
        .compile_protos(&[metric_proto_path], &[metric_proto_root])?;

    println!("cargo:rerun-if-changed={metric_proto_path}");

    Ok(())
}
