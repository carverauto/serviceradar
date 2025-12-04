# Change: Integrate edge onboarding into sysmon (Rust) package

## Why
- The Rust-based `sysmon` checker lacks edge onboarding support, requiring manual configuration for SPIFFE/mTLS deployments.
- `sysmon-osx` (Go) already supports edge onboarding via the `pkg/edgeonboarding` package, demonstrating the pattern and proving customer value.
- Customers deploying `sysmon` on Linux edge nodes need the same zero-touch token-based install experience available to `sysmon-osx` users.
- The Rust sysmon checker is the primary system monitoring solution for Linux deployments and should have feature parity with sysmon-osx.

## What Changes
- Create a Rust edge onboarding library (`rust/edge-onboarding`) that ports the core functionality from `pkg/edgeonboarding` (Go), including:
  - Token parsing and validation (`edgepkg-v1:` format)
  - Package download from Core API
  - mTLS bundle installation
  - SPIFFE/SPIRE credential configuration
  - Deployment type detection (Docker, Kubernetes, bare-metal)
- Integrate the edge onboarding library into `cmd/checkers/sysmon/src/main.rs`:
  - Add `--mtls` flag for mTLS-only bootstrap (parallel to sysmon-osx)
  - Add environment variable support: `ONBOARDING_TOKEN`, `KV_ENDPOINT`, `CORE_API_URL`
  - Generate and persist configuration from onboarding package
- Support both onboarding paths:
  - **mTLS path**: Token + host downloads CA + client cert/key bundle
  - **SPIRE path**: Token + KV endpoint configures SPIRE workload API credentials
- Update Docker/Compose and Kubernetes manifests to support edge-onboarded sysmon checkers.

## Status (2025-12-04)
- Created `rust/edge-onboarding` crate with token parsing, package download, mTLS bundle installation, deployment detection, and config generation.
- Integrated edge-onboarding into sysmon checker with CLI flags (`--mtls`, `--token`, `--host`, `--bundle`, `--cert-dir`) and environment variable support.
- All 14 unit tests passing.
- Documentation updated in README.
- Dockerfile updated with edge onboarding environment variables and directories.
- **E2E Validation Complete:**
  - mTLS bootstrap tested with Docker Compose stack - certificates installed with proper permissions.
  - Restart resilience verified - checker uses persisted config/certs on restart.
  - Error handling verified - clear messages for invalid/expired tokens.
- **Deferred:**
  - SPIRE-based onboarding (requires SPIRE infrastructure).
  - ARM64 cross-platform testing.

## Impact
- Affected specs: edge-onboarding.
- Affected code:
  - New: `rust/edge-onboarding/` crate
  - Modified: `cmd/checkers/sysmon/src/main.rs`, `cmd/checkers/sysmon/Cargo.toml`
  - Modified: Docker Compose checker configs, Helm chart checker templates (if applicable)
- Dependencies: `reqwest` (HTTP client), `serde_json` (JSON parsing), `base64` (token decoding)
