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

    // Compile monitoring protos
    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&descriptor_path)
        .type_attribute(".", "#[allow(dead_code)]")
        .compile(&[proto_path], &[proto_dir])?;
    println!("cargo:rerun-if-changed={proto_path}");

    // Compile OTEL protos - try multiple paths for Docker compatibility
    let otel_paths = vec![
        "../../otel/proto",
        "../otel/proto",
        "./otel/proto",
        "./cmd/otel/proto",
        "../cmd/otel/proto"
    ];
    
    let mut otel_base = None;
    for path in otel_paths {
        if Path::new(path).exists() {
            otel_base = Some(path);
            break;
        }
    }
    
    if let Some(otel_base) = otel_base {
        let logs_proto = format!("{otel_base}/opentelemetry/proto/logs/v1/logs.proto");
        let common_proto = format!("{otel_base}/opentelemetry/proto/common/v1/common.proto");
        let resource_proto = format!("{otel_base}/opentelemetry/proto/resource/v1/resource.proto");
        
        if Path::new(&logs_proto).exists() && Path::new(&common_proto).exists() && Path::new(&resource_proto).exists() {
            tonic_build::configure()
                .build_server(false)
                .build_client(false)
                .compile(
                    &[&logs_proto, &common_proto, &resource_proto],
                    &[otel_base],
                )?;
            println!("cargo:rerun-if-changed={}", logs_proto);
            println!("cargo:rerun-if-changed={}", common_proto);
            println!("cargo:rerun-if-changed={}", resource_proto);
        }
    }

    Ok(())
}