use std::{env, path::Path};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let proto_path = if Path::new("proto/agent/netprobe/v1/netprobe.proto").exists() {
        "proto/agent/netprobe/v1/netprobe.proto"
    } else {
        "../../proto/agent/netprobe/v1/netprobe.proto"
    };

    println!("cargo:rerun-if-changed={proto_path}");

    let out_dir = env::var("OUT_DIR")?;
    prost_build::Config::new()
        .out_dir(out_dir)
        .compile_protos(&[proto_path], &[".", "proto", "../../proto"])?;

    Ok(())
}
