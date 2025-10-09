use std::env;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var("OUT_DIR").unwrap();
    let descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");
    let proto_path = if Path::new("proto/monitoring.proto").exists() {
        "proto/monitoring.proto"
    } else {
        "../../../proto/monitoring.proto"
    };
    let proto_dir = Path::new(proto_path).parent().unwrap();

    tonic_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&descriptor_path)
        .type_attribute(".", "#[allow(dead_code)]")
        .compile_protos(&[proto_path], &[proto_dir])?;
    println!("cargo:rerun-if-changed={proto_path}");

    // Compile OTEL protos
    let otel_base = "../../otel/proto";
    if Path::new(otel_base).exists() {
        tonic_build::configure()
            .protoc_arg("--experimental_allow_proto3_optional")
            .build_server(false)
            .build_client(false)
            .compile_protos(
                &[
                    &format!("{otel_base}/opentelemetry/proto/logs/v1/logs.proto"),
                    &format!("{otel_base}/opentelemetry/proto/common/v1/common.proto"),
                    &format!("{otel_base}/opentelemetry/proto/resource/v1/resource.proto"),
                    &format!("{otel_base}/opentelemetry/proto/metrics/v1/metrics.proto"),
                    &format!(
                        "{otel_base}/opentelemetry/proto/collector/metrics/v1/metrics_service.proto"
                    ),
                ],
                &[otel_base],
            )?;
        println!("cargo:rerun-if-changed={otel_base}/opentelemetry/proto/logs/v1/logs.proto");
        println!("cargo:rerun-if-changed={otel_base}/opentelemetry/proto/common/v1/common.proto");
        println!(
            "cargo:rerun-if-changed={otel_base}/opentelemetry/proto/resource/v1/resource.proto"
        );
        println!("cargo:rerun-if-changed={otel_base}/opentelemetry/proto/metrics/v1/metrics.proto");
        println!("cargo:rerun-if-changed={otel_base}/opentelemetry/proto/collector/metrics/v1/metrics_service.proto");
    }

    Ok(())
}
