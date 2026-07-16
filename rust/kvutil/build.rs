use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Resolve kv.proto relative to this crate
    let kv_proto = if Path::new("proto/kv.proto").exists() {
        "proto/kv.proto"
    } else if Path::new("../../proto/kv.proto").exists() {
        "../../proto/kv.proto"
    } else {
        panic!("kv.proto not found relative to crate");
    };
    let inc = Path::new(kv_proto).parent().unwrap();
    tonic_prost_build::configure()
        .build_server(false)
        .build_client(true)
        .compile_protos(&[Path::new(kv_proto)], &[inc])?;
    println!("cargo:rerun-if-changed={kv_proto}");
    Ok(())
}
