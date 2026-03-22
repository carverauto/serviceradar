# Rust Dependency Updates with Bazel

ServiceRadar's Rust dependencies are consumed by Bazel `rules_rust` crate-universe
from the repository root `Cargo.lock`.

The supported update path is:

```bash
scripts/update-rust-bazel-deps.sh [repin-mode] [verify-target]
```

Examples:

```bash
# Update the existing workspace dependency graph
scripts/update-rust-bazel-deps.sh

# Update all resolvable crates eagerly
scripts/update-rust-bazel-deps.sh full

# Update a specific package
scripts/update-rust-bazel-deps.sh diesel

# Update a specific package to an exact version
scripts/update-rust-bazel-deps.sh diesel@2.3.7
```

What the script does:

1. Updates the root `Cargo.lock` with a targeted `cargo update`.
2. Refreshes `MODULE.bazel.lock` with `bazel mod deps --lockfile_mode=update`.
3. Verifies a representative Rust Bazel target with `bazel build --nobuild`.

This keeps `Cargo.lock`, the generated crate-universe repository, and
`MODULE.bazel.lock` coherent.

Do not stop after `cargo update`. If `MODULE.bazel.lock` is not regenerated,
Bazel can fail while resolving the crate-universe repository.
