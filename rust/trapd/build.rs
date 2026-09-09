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
    let automation_launch_envelope_proto = proto_dir.join("automation_launch_envelope.proto");

    tonic_prost_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&descriptor_path)
        .type_attribute(".", "#[allow(clippy::large_enum_variant)]")
        .compile_protos(&[Path::new(proto_path)], &[proto_dir])?;
    println!("cargo:rerun-if-changed={proto_path}");
    println!(
        "cargo:rerun-if-changed={}",
        automation_launch_envelope_proto.display()
    );

    println!(
        "cargo:rerun-if-changed={}",
        proto_dir.join("edge/v1/record.proto").display()
    );

    // Compile KV proto for client usage
    let kv_proto_path = if Path::new("proto/kv.proto").exists() {
        "proto/kv.proto"
    } else {
        "../../proto/kv.proto"
    };
    let kv_proto_dir = Path::new(kv_proto_path).parent().unwrap();
    tonic_prost_build::configure()
        .build_server(false)
        .build_client(true)
        .compile_protos(&[Path::new(kv_proto_path)], &[kv_proto_dir])?;
    println!("cargo:rerun-if-changed={kv_proto_path}");
    Ok(())
}
