/*
 * Copyright (c) "2025" . Marvin Hansen All Rights Reserved.
 */

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .compile_protos(
            &["proto/api.proto"],
            &["proto"],
        )
        .expect("Failed to compile proto specification");

    Ok(())
}
