# Change: Reduce Rust/OpenSSL Perl Toolchain Dependency in Bazel Builds

## Why
Current Bazel Rust builds may trigger hermetic Perl source bootstrapping because vendored OpenSSL (`openssl-src`) requires Perl at build time. This adds significant cold-build time and complexity for local development and CI troubleshooting.

## What Changes
- Introduce an explicit Rust/OpenSSL Perl strategy for Bazel builds with a faster default path.
- Prefer host-provided Perl for OpenSSL vendored builds in supported environments, while keeping a hermetic fallback mode.
- Define guardrails for environments where host Perl is unavailable or disallowed.
- Document tradeoffs and operational controls for local, CI, and remote-executor builds.
- Add observability and acceptance checks to ensure build reproducibility and avoid regressions.

## Impact
- Affected specs: `rust-build-toolchain` (new)
- Affected code:
  - `MODULE.bazel`
  - `MODULE.bazel.lock` (generated)
  - `third_party/perl/*`
  - Rust/Bazel crate-universe generation inputs for `openssl-sys` / `openssl-src`
  - Build docs (`README`, runbooks)
