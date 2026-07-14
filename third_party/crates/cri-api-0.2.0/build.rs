/**
 * Copyright (2024, ) Institute of Software, Chinese Academy of Sciences
 * since 0.1.1
 **/

fn main() {
    tonic_build::configure()
        .type_attribute(".", "#[derive(serde::Serialize, serde::Deserialize)]")
        .compile_protos(&["proto/v1.proto"], &["proto/"])
        .unwrap();

}
