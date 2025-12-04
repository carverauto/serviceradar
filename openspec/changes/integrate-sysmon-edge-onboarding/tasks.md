## 1. Design & Decisions
- [x] 1.1 Finalize Rust crate scope: general-purpose vs sysmon-specific initially.
  - Decision: Start sysmon-specific, can generalize later for other Rust checkers.
- [x] 1.2 Decide async vs sync HTTP for bootstrap phase (recommend sync for simplicity).
  - Decision: Use `ureq` for blocking HTTP - simpler for one-time bootstrap at startup.
- [x] 1.3 Define storage paths and file permissions for credentials on Linux.
  - Decision: `/var/lib/serviceradar/checker/` with 0644 for certs, 0600 for keys.
- [x] 1.4 Review Go edgeonboarding package for portable logic vs Go-specific implementation.
  - Reviewed: Ported token parsing, mTLS bundle, deployment detection, config generation.

## 2. Rust Edge Onboarding Crate (`rust/edge-onboarding`)
- [x] 2.1 Create crate structure with `Cargo.toml`, `src/lib.rs`, and module layout.
- [x] 2.2 Implement token parsing: `parse_token(token: &str) -> Result<TokenPayload>`.
- [x] 2.3 Implement package download: `download_package(payload: &TokenPayload) -> Result<Package>`.
- [x] 2.4 Implement mTLS bundle installation: `install_mtls_bundle(bundle: &MtlsBundle, path: &Path) -> Result<()>`.
- [x] 2.5 Implement SPIRE credential setup: `configure_spire(join_token: &str, bundle_pem: &str, path: &Path) -> Result<SpireConfig>`.
  - Note: Basic support included; full SPIRE workload API integration deferred.
- [x] 2.6 Implement config generation: `generate_config(package: &Package, security: &SecurityConfig) -> Result<Config>`.
- [x] 2.7 Implement deployment detection: `detect_deployment() -> DeploymentType` (Docker, Kubernetes, bare-metal).
- [x] 2.8 Implement main entry point: `try_onboard(component_type: ComponentType) -> Result<Option<OnboardingResult>>`.
- [x] 2.9 Add unit tests for token parsing, config generation, and deployment detection.
  - 14 tests passing.
- [x] 2.10 Add integration test with mock Core API responses.
  - Basic tests included; full integration tests deferred to validation phase.

## 3. Sysmon Checker Integration (`cmd/checkers/sysmon`)
- [x] 3.1 Add `edge-onboarding` crate as a dependency in `Cargo.toml`.
- [x] 3.2 Add CLI flags: `--mtls`, `--token <TOKEN>`, `--host <HOST>`, `--cert-dir <PATH>`.
- [x] 3.3 Implement mTLS bootstrap path in `main.rs` before config loading.
- [x] 3.4 Implement SPIRE/env-based bootstrap path (`ONBOARDING_TOKEN` + `KV_ENDPOINT`).
- [x] 3.5 Merge generated security config with base config when onboarding succeeds.
- [x] 3.6 Persist onboarding result for restart resilience (detect existing credentials).
- [x] 3.7 Update config validation to handle onboarding-generated configs.
- [x] 3.8 Add logging for onboarding steps (token received, package downloaded, certs installed).

## 4. Documentation & Packaging
- [x] 4.1 Update `cmd/checkers/sysmon/README.md` with edge onboarding usage.
- [x] 4.2 Add environment variable documentation: `ONBOARDING_TOKEN`, `KV_ENDPOINT`, `CORE_API_URL`.
- [x] 4.3 Document mTLS CLI usage: `sysmon-checker --mtls --token <TOKEN> --host <HOST>`.
- [x] 4.4 Update Dockerfile to support onboarding environment variables.
  - Added `ONBOARDING_TOKEN`, `CORE_API_URL`, `KV_ENDPOINT` env vars.
  - Created `/var/lib/serviceradar/checker/` directories for certs and config.
  - Updated CMD to auto-detect onboarding mode.

## 5. Validation
- [x] 5.1 E2E: Start Compose stack, issue mTLS edge token, run sysmon checker with `--mtls`, verify mTLS connection to poller.
  - Tested with Docker Compose mTLS stack.
  - Created edge package via Core API.
  - Downloaded bundle, installed certs (0644 for certs, 0600 for keys).
  - Generated config at `/var/lib/serviceradar/checker/config/checker.json`.
  - Started mTLS-enabled gRPC server successfully.
- [ ] 5.2 E2E: Issue SPIRE-based package, run sysmon with `ONBOARDING_TOKEN`, verify SPIFFE identity.
  - Deferred: Requires SPIRE infrastructure not currently available in test environment.
- [x] 5.3 Restart resilience: Verify sysmon restarts successfully using persisted credentials.
  - Verified: Checker starts with `--config /path/to/checker.json` using persisted certs.
- [x] 5.4 Negative test: Verify graceful fallback when token is invalid or expired.
  - Tested invalid base64 token: Clear error message about decode failure.
  - Tested invalid download token: 409 error surfaced with clear API error message.
- [ ] 5.5 Cross-platform: Verify onboarding works on both amd64 and arm64 Linux.
  - Deferred: Tested on x86_64 Linux; ARM testing requires separate environment.
