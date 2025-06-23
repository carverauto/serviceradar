use std::env;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var("OUT_DIR").unwrap();
    let descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");
    let proto_path = if Path::new("proto/monitoring.proto").exists() {
        "proto/monitoring.proto"
    } else {
        "../../proto/monitoring.proto"
    };
    let proto_dir = Path::new(proto_path).parent().unwrap();

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&descriptor_path)
        .compile(&[proto_path], &[proto_dir])?;
    println!("cargo:rerun-if-changed={}", proto_path);
    Ok(())
}
