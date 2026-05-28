use std::{env, path::Path};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=ebpf/Cargo.toml");
    println!("cargo:rerun-if-changed=ebpf/src/lib.rs");
    println!("cargo:rerun-if-env-changed=SERVICERADAR_NETPROBE_BUILD_EBPF");

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

    if env::var_os("SERVICERADAR_NETPROBE_BUILD_EBPF").is_some() {
        aya_build::build_ebpf(
            [aya_build::Package {
                name: "serviceradar-netprobe-ebpf",
                root_dir: "ebpf",
                no_default_features: false,
                features: &[],
            }],
            aya_build::Toolchain::Nightly,
        )?;
    }

    Ok(())
}
