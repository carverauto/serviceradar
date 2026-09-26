//! SRQL dialect parity harness (openspec change extend-starrocks-to-all-telemetry, 1.4-1.6).
//!
//! * `inventory.json` + `inventory`: the checked-in query shapes, each with its expectation and,
//!   where the backends may differ, a named deviation with its reason.
//! * `coverage` + `scan` + `shape`: the source scan that fails when a product chart query has
//!   no inventory entry.
//! * `fixture`: the one synthetic row generator both backends are seeded from.
//! * `schema`: the DDL each throwaway database is built from.
//! * `compare`: result normalisation and the diff.
//! * `runner`: seeds CNPG and StarRocks, runs every entry through both dialects, reports.

pub mod compare;
pub mod coverage;
pub mod fixture;
pub mod inventory;
pub mod runner;
pub mod scan;
pub mod schema;
pub mod shape;

use std::path::PathBuf;

/// The repository root: the Bazel runfiles tree under `bazel test`, the workspace under cargo.
///
/// Read at run time, never `env!`: a path baked in at compile time is the executor's, and the
/// Bazel process wrapper refuses output that embeds its working directory.
pub fn repo_root() -> PathBuf {
    const MARKER: &str = "integration_tests/srql_parity/inventory.json";
    if let Ok(runfiles) = runfiles::Runfiles::create() {
        for repo in ["_main", "serviceradar"] {
            if let Some(path) = runfiles.rlocation(format!("{repo}/{MARKER}"))
                && path.exists()
                && let Some(root) = path.ancestors().nth(3)
            {
                return root.to_path_buf();
            }
        }
    }
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let root = PathBuf::from(manifest_dir).join("../..");
        if root.join(MARKER).exists() {
            return root;
        }
    }
    panic!(
        "cannot locate the repository: neither Bazel runfiles nor CARGO_MANIFEST_DIR hold {MARKER}"
    );
}
