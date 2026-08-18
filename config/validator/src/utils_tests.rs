//! Locates declared data inputs from a test binary.

use std::path::{Path, PathBuf};

/// `cargo test` runs with the crate root as the working directory; Bazel runs the test binary
/// out of the runfiles tree, where a bare relative path resolves to nothing. Same idiom as
/// flowgger's fixture_path and netprobe's corpus lookup.
///
/// `CARGO_MANIFEST_DIR` is read rather than `env!`'d because the compile-time value under Bazel
/// is an execroot path that does not exist when the test runs.
pub fn data_path(relative: &str) -> PathBuf {
    if let Ok(dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let candidate = Path::new(&dir).join("../..").join(relative);
        if candidate.exists() {
            return candidate;
        }
    }
    if let Ok(srcdir) = std::env::var("TEST_SRCDIR") {
        let root = PathBuf::from(srcdir);
        for workspace in ["_main", "serviceradar"] {
            let candidate = root.join(workspace).join(relative);
            if candidate.exists() {
                return candidate;
            }
        }
    }
    PathBuf::from(relative)
}

pub fn read(relative: &str) -> String {
    let path = data_path(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"))
}

/// The instances every instance-wide check iterates. Named explicitly rather than globbed: a
/// new instance must be added here deliberately, so it cannot land in the tree and silently go
/// unchecked.
/// Stems relative to `config/environments/`, so an on-prem instance in its own package is
/// named the same way it is stored.
pub const INSTANCES: &[&str] = &["ci", "demo", "localhost", "onprem/untd", "saas"];

/// A runfile path, or None if it was not declared. Unlike [`data_path`] this does NOT fall back
/// to the source tree: the point of the caller is to distinguish declared from undeclared, and a
/// fallback would find files the target never asked for.
pub fn runfile(relative: &str) -> Option<std::path::PathBuf> {
    let srcdir = std::env::var("TEST_SRCDIR").expect("TEST_SRCDIR: this test needs a runfiles tree");
    let root = std::path::PathBuf::from(srcdir);
    ["_main", "serviceradar"]
        .iter()
        .map(|w| root.join(w).join(relative))
        .find(|c| c.exists())
}
