fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .disable_comments(".") // Disable comments to avoid doctest issues
        .compile_protos(
            &[
                "proto/opentelemetry/proto/collector/trace/v1/trace_service.proto",
                "proto/opentelemetry/proto/trace/v1/trace.proto",
                "proto/opentelemetry/proto/resource/v1/resource.proto",
                "proto/opentelemetry/proto/common/v1/common.proto",
            ],
            &["proto"],
        )?;
    Ok(())
}