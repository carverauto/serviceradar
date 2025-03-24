fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_server(true)  // Ensure server code is generated
        .build_client(false) // Optional: disable client if not needed
        .compile(&["src/proto/rperf.proto"], &["src/proto"])?;
    println!("cargo:rerun-if-changed=src/proto/rperf.proto");
    Ok(())
}