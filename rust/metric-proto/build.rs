fn main() -> Result<(), Box<dyn std::error::Error>> {
    let metric_proto_path = "../../proto/metric/v1/metric.proto";

    tonic_prost_build::configure()
        .build_server(false)
        .build_client(false)
        .disable_comments(["."])
        .compile_protos(&[metric_proto_path], &["../../proto"])?;

    println!("cargo:rerun-if-changed={metric_proto_path}");

    Ok(())
}
