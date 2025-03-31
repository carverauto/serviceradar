use std::env;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var("OUT_DIR").unwrap();
    let rperf_descriptor_path = Path::new(&out_dir).join("rperf_descriptor.bin");
    let monitoring_descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&rperf_descriptor_path)
        .compile(&["src/proto/rperf.proto"], &["src/proto"])?;

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&monitoring_descriptor_path)
        .compile(&["src/proto/monitoring.proto"], &["src/proto"])?;

    println!("cargo:rerun-if-changed=src/proto/rperf.proto");
    println!("cargo:rerun-if-changed=src/proto/monitoring.proto");
    Ok(())
}