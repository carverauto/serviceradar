use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Generate the CRI runtime client from the vendored proto instead of depending on the
    // cri-api crate, which is built against tonic 0.12 and would drag that whole stack
    // (tonic 0.12, tonic-build 0.12, prost-build 0.13, axum 0.7) back into the workspace.
    let proto = if Path::new("proto/cri/v1.proto").exists() {
        "proto/cri/v1.proto"
    } else {
        "../../proto/cri/v1.proto"
    };
    let include = Path::new(proto).parent().expect("proto has a parent dir");

    // Client only: nothing here serves the CRI API. cri-api also derived serde on every
    // message; this crate never serializes them, so those derives are left out.
    tonic_prost_build::configure()
        .build_server(false)
        .build_client(true)
        .compile_protos(&[Path::new(proto)], &[include])?;

    println!("cargo:rerun-if-changed={proto}");

    Ok(())
}
