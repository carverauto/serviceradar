# Design: Fix edge onboarding mTLS cert_dir path traversal

## Context
The Core edge onboarding service can issue packages in mTLS mode. During package creation, Core reads a CA certificate and private key from disk in order to mint a client certificate for the edge component.

Today, the CA file paths are derived from user-controlled metadata fields (`cert_dir`, `ca_cert_path`, `ca_key_path`). Although Core checks that `ca_*_path` are within `cert_dir`, `cert_dir` itself is not constrained to a trusted base directory.

## Goals
- Prevent authenticated users from causing Core to read arbitrary files from the filesystem during mTLS package issuance.
- Keep operator flexibility to place CA material in a non-default directory via Core configuration.
- Provide clear client errors when requests attempt to escape the allowed directory.

## Non-Goals
- Redesign the edge onboarding metadata schema beyond what is required to close the vulnerability.
- Change how SPIFFE/SPIRE packages are generated.

## Decisions
- Decision: Introduce a Core-configured “mTLS CA base directory” (default `/etc/serviceradar/certs`) and enforce that any CA file reads are confined to it.
- Decision: Validate paths using `filepath.Rel` (and optionally `filepath.EvalSymlinks` if needed) rather than prefix checks on raw strings.
- Decision: Treat escape attempts as invalid requests (HTTP 400) and ensure Core does not attempt to read the referenced paths.

## Risks / Trade-offs
- Tightening validation may break workflows that relied on passing arbitrary filesystem paths via `metadata_json`. This is an acceptable trade-off for closing a security issue; operators can migrate by configuring the base directory appropriately.
- Symlink traversal is not addressed by `filepath.Abs` alone; if the Core host’s CA directory contains attacker-controlled symlinks, additional hardening (EvalSymlinks / `openat`-style checks) may be required.

## Migration Plan
1. Ship the Core config option with default `/etc/serviceradar/certs`.
2. Reject package creation requests that specify `cert_dir` outside the configured base directory.
3. Update docs and examples to avoid implying that `cert_dir` can point anywhere on the Core host.

## Open Questions
- Should Core ignore user-provided `ca_cert_path` / `ca_key_path` entirely (always using `root.pem` / `root-key.pem`), or keep allowing overrides as long as they remain under the allowed base directory?
- Should we tighten validation for `metadata_json.cert_dir` (used as a template variable) to prevent surprising edge-side file locations, even though it no longer influences Core-side CA reads?
