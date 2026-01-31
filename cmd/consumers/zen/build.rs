use std::env;
use std::path::{Path, PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var("OUT_DIR").unwrap();
    let descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR")?);
    let repo_root = manifest_dir.join("../../..");
    let proto_dir = repo_root.join("proto");
    let proto_path = proto_dir.join("monitoring.proto");

    tonic_build::configure()
        .protoc_arg("--experimental_allow_proto3_optional")
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&descriptor_path)
        .type_attribute(".", "#[allow(dead_code)]")
        .compile_protos(&[&proto_path], &[&proto_dir])?;
    println!("cargo:rerun-if-changed={}", proto_path.display());

    // Compile OTEL protos
    let otel_base = repo_root.join("cmd/otel/proto");
    if otel_base.exists() {
        let otel_files = [
            otel_base.join("opentelemetry/proto/logs/v1/logs.proto"),
            otel_base.join("opentelemetry/proto/common/v1/common.proto"),
            otel_base.join("opentelemetry/proto/resource/v1/resource.proto"),
            otel_base.join("opentelemetry/proto/metrics/v1/metrics.proto"),
            otel_base.join("opentelemetry/proto/collector/metrics/v1/metrics_service.proto"),
        ];
        tonic_build::configure()
            .protoc_arg("--experimental_allow_proto3_optional")
            .build_server(false)
            .build_client(false)
            .compile_protos(&otel_files, &[otel_base.as_path()])?;
        println!(
            "cargo:rerun-if-changed={}",
            otel_files[0].display()
        );
        println!(
            "cargo:rerun-if-changed={}",
            otel_files[1].display()
        );
        println!(
            "cargo:rerun-if-changed={}",
            otel_files[2].display()
        );
        println!(
            "cargo:rerun-if-changed={}",
            otel_files[3].display()
        );
        println!(
            "cargo:rerun-if-changed={}",
            otel_files[4].display()
        );
    }

    // Compile flow.proto
    let flow_proto = proto_dir.join("flow/flow.proto");
    let flow_dir = proto_dir.join("flow");
    if flow_proto.exists() {
        tonic_build::configure()
            .protoc_arg("--experimental_allow_proto3_optional")
            .build_server(false)
            .build_client(false)
            .compile_protos(&[&flow_proto], &[&flow_dir])?;
        println!("cargo:rerun-if-changed={}", flow_proto.display());
    }

    Ok(())
}
