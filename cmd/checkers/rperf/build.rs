fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_server(true)
        .build_client(false)  // Only server is needed for this use case
        .compile(&["src/proto/rperf.proto"], &["src/proto"])?;
    println!("cargo:rerun-if-changed=src/proto/rperf.proto");
    Ok(())
}