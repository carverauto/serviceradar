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

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var("OUT_DIR").unwrap();
    let rperf_descriptor_path = Path::new(&out_dir).join("rperf_descriptor.bin");
    let monitoring_descriptor_path = Path::new(&out_dir).join("monitoring_descriptor.bin");

    // Force tonic/prost to use a known protoc: prefer an injected PROTOC (from Bazel)
    // then fall back to platform defaults.
    let protoc_env = env::var("PROTOC").ok();
    let resolved_protoc = match protoc_env {
        Some(candidate) => normalize_exe(&candidate)
            .or_else(|_| resolve_in_runfiles(&candidate))
            .or_else(|_| which::which(&candidate))
            .ok(),
        None => None,
    };

    if let Some(protoc) = resolved_protoc {
        env::set_var("PROTOC", protoc);
    } else if let Ok(protoc) = which::which("protoc") {
        env::set_var("PROTOC", protoc);
    } else if !cfg!(target_os = "macos") {
        env::set_var("PROTOC", "/usr/bin/protoc");
    }

    if cfg!(target_os = "macos") {
        // For macOS with Homebrew
        if Path::new("/opt/homebrew/opt/protobuf/include").exists() {
            env::set_var("PROTOC_INCLUDE", "/opt/homebrew/opt/protobuf/include");
        } else if Path::new("/usr/local/opt/protobuf/include").exists() {
            env::set_var("PROTOC_INCLUDE", "/usr/local/opt/protobuf/include");
        }
    } else {
        env::set_var("PROTOC_INCLUDE", "/usr/include");
    }

    if let Ok(protoc) = env::var("PROTOC") {
        println!("cargo:warning=PROTOC={}", protoc);
        if !Path::new(&protoc).exists() {
            return Err(format!("protoc not found at {}", protoc).into());
        }
    }

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&rperf_descriptor_path)
        .compile(&["src/proto/rperf.proto"], &["src/proto"])?;

    tonic_build::configure()
        .build_server(true)
        .build_client(false)
        .file_descriptor_set_path(&monitoring_descriptor_path)
        .compile(&["src/proto/monitoring.proto"], &["src/proto"])?;

    println!("cargo:rerun-if-changed=src/proto/rperf.proto");
    println!("cargo:rerun-if-changed=src/proto/monitoring.proto");
    Ok(())
}

fn normalize_exe(path: &str) -> Result<std::path::PathBuf, std::io::Error> {
    let p = Path::new(path);
    if p.is_absolute() {
        std::fs::canonicalize(p)
    } else {
        let cwd = env::current_dir()?;
        std::fs::canonicalize(cwd.join(p))
    }
}

fn resolve_in_runfiles(path: &str) -> Result<std::path::PathBuf, std::io::Error> {
    let runfiles = match env::var("RUNFILES_DIR") {
        Ok(dir) => dir,
        Err(_) => return Err(std::io::Error::new(std::io::ErrorKind::NotFound, "RUNFILES_DIR unset")),
    };
    std::fs::canonicalize(Path::new(&runfiles).join(path))
}
