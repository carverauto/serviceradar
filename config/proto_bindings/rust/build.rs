//! Generates Rust types from the configuration schema.
//!
//! prost, like every other implementation here, cannot parse text format -- it consumes the
//! binary produced by the protoc action in //config/environments. This build script only
//! generates the TYPES; loading is the manager's job.

use std::path::{Path, PathBuf};

/// Walks upward from the working directory looking for the schema.
///
/// Cargo runs from the crate directory and Bazel restores the execroot (see the
/// symlink-exec-root note in BUILD.bazel), so the depth differs between the two. Searching
/// rather than hard-coding `../../..` means moving this crate does not silently break the
/// build script -- it would fail loudly here instead of finding a stale copy.
fn schema_root() -> PathBuf {
    let mut dir = PathBuf::from(".");
    for _ in 0..8 {
        if dir.join("config/proto/config.proto").exists() {
            return dir;
        }
        dir = dir.join("..");
    }
    panic!("config/proto/config.proto not found within 8 levels of {:?}", std::env::current_dir());
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = schema_root();
    let config_proto = root.join("config/proto/config.proto");
    let rules_proto = root.join("config/proto/rules.proto");

    prost_build::Config::new()
        .compile_protos(&[Path::new(&config_proto), Path::new(&rules_proto)], &[&root])?;

    println!("cargo:rerun-if-changed={}", config_proto.display());
    println!("cargo:rerun-if-changed={}", rules_proto.display());
    Ok(())
}
