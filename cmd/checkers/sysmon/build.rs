/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use std::env;
use std::path::Path;
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR")?;
    let out_dir = env::var("OUT_DIR").unwrap();
    let monitoring_descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");
    let proto_dir = PathBuf::from(&manifest_dir).join("../../../proto");
    let proto_path = proto_dir.join("monitoring.proto");

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(monitoring_descriptor_path)
        .compile(
            std::slice::from_ref(&proto_path),
            std::slice::from_ref(&proto_dir),
        )?;

    println!("cargo:rerun-if-changed={}", proto_path.display());
    Ok(())
}
