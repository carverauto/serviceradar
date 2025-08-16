use std::env;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:warning=Starting build.rs");
    
    let out_dir = env::var("OUT_DIR").unwrap();
    println!("cargo:warning=OUT_DIR={}", out_dir);
    
    let descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");
    let proto_path = if Path::new("proto/monitoring.proto").exists() {
        println!("cargo:warning=Found proto/monitoring.proto");
        "proto/monitoring.proto"
    } else {
        println!("cargo:warning=Using ../../../proto/monitoring.proto");
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

    // Compile OTEL protos - try multiple paths
    let otel_paths = vec![
        "../../otel/proto",
        "../otel/proto",
        "./otel/proto",
        "./cmd/otel/proto",
        "../cmd/otel/proto"
    ];
    
    let mut otel_base = None;
    for path in otel_paths {
        println!("cargo:warning=Checking OTEL path: {}", path);
        if Path::new(path).exists() {
            println!("cargo:warning=OTEL path exists: {}", path);
            otel_base = Some(path);
            break;
        }
    }
    
    if let Some(otel_base) = otel_base {
        println!("cargo:warning=Using OTEL base path: {}", otel_base);
        
        let logs_proto = format!("{otel_base}/opentelemetry/proto/logs/v1/logs.proto");
        let common_proto = format!("{otel_base}/opentelemetry/proto/common/v1/common.proto");
        let resource_proto = format!("{otel_base}/opentelemetry/proto/resource/v1/resource.proto");
        
        println!("cargo:warning=Checking logs proto: {}", logs_proto);
        println!("cargo:warning=Logs proto exists: {}", Path::new(&logs_proto).exists());
        println!("cargo:warning=Checking common proto: {}", common_proto);
        println!("cargo:warning=Common proto exists: {}", Path::new(&common_proto).exists());
        println!("cargo:warning=Checking resource proto: {}", resource_proto);
        println!("cargo:warning=Resource proto exists: {}", Path::new(&resource_proto).exists());
        
        if Path::new(&logs_proto).exists() && Path::new(&common_proto).exists() && Path::new(&resource_proto).exists() {
            println!("cargo:warning=All OTEL proto files found, compiling...");
            
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
            
            println!("cargo:warning=OTEL proto compilation completed successfully");
        } else {
            println!("cargo:warning=Some OTEL proto files are missing, skipping OTEL compilation");
        }
    } else {
        println!("cargo:warning=No valid OTEL base path found, skipping OTEL compilation");
    }

    println!("cargo:warning=Build script completed");
    Ok(())
}