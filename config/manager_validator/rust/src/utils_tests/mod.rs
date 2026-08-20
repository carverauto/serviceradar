//! Locates declared data inputs from a test binary.

use runfiles::Runfiles;
use std::path::{Path, PathBuf};

/// This module's own repository, as MODULE.bazel declares it. The first segment of an rlocation
/// path is an APPARENT repository name, which the runfiles repo mapping resolves to the
/// canonical directory.
const THIS_REPO: &str = "serviceradar";

/// The main repository's canonical name is empty in the repo mapping. This is what the
/// `rlocation!` macro would pass; the macro itself is unusable here because it resolves the name
/// at COMPILE time from an environment variable only rules_rust sets, and this crate also builds
/// under plain `cargo`.
const THIS_REPO_CANONICAL: &str = "";

/// Resolution through the Bazel ecosystem's reference implementation
/// (`@rules_rust//rust/runfiles`, published as the `runfiles` crate).
///
/// This replaced a hand-rolled lookup that read `TEST_SRCDIR` and then tried `_main` and
/// `serviceradar` in turn. Two things were wrong with that beyond the guessing: it found nothing
/// under `bazel run`, where neither `TEST_SRCDIR` nor `RUNFILES_DIR` is set and the tree must be
/// derived from `argv[0]`; and it located files with `Path::exists`, which cannot work in
/// MANIFEST mode, where runfiles is a text manifest rather than a symlink tree.
fn from_runfiles(runfiles: &Runfiles, relative: &str) -> Option<PathBuf> {
    let path = runfiles.rlocation_from(format!("{THIS_REPO}/{relative}"), THIS_REPO_CANONICAL)?;
    path.exists().then_some(path)
}

/// `cargo test` runs with the crate root as the working directory; Bazel runs the test binary
/// out of the runfiles tree, where a bare relative path resolves to nothing. Same idiom as
/// flowgger's fixture_path and netprobe's corpus lookup.
///
/// `CARGO_MANIFEST_DIR` is read rather than `env!`'d because the compile-time value under Bazel
/// is an execroot path that does not exist when the test runs.
pub fn data_path(relative: &str) -> PathBuf {
    if let Ok(dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let candidate = Path::new(&dir).join("../../..").join(relative);
        if candidate.exists() {
            return candidate;
        }
    }
    if let Ok(runfiles) = Runfiles::create()
        && let Some(path) = from_runfiles(&runfiles, relative)
    {
        return path;
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
    // Absent runfiles is a different failure from an undeclared input, and must stay loud: the
    // caller reads None as "the target did not declare this", which would be a false negative.
    let runfiles = Runfiles::create().expect("this test needs a runfiles tree");
    from_runfiles(&runfiles, relative)
}
