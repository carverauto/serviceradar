fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Compile protobuf files
    tonic_build::configure()
        .disable_comments(".") // Disable comments to avoid doctest issues
        .compile_protos(
            &["../proto/profiler/profiler.proto"],
            &["../proto"],
        )?;

    Ok(())
}