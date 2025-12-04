## Context
- The Rust sysmon checker (`cmd/checkers/sysmon/`) provides system metrics (CPU, memory, disk, ZFS) via gRPC but requires manual configuration.
- The Go sysmon-osx checker (`cmd/checkers/sysmon-osx/`) demonstrates edge onboarding integration via `edgeonboarding.TryOnboard()`, supporting both mTLS and SPIRE paths.
- The existing Go edgeonboarding package (`pkg/edgeonboarding/`) handles:
  - Token parsing: `edgepkg-v1:<base64url-encoded-json>` containing `{pkg, dl, api}`
  - Package download: `POST /api/admin/edge-packages/{id}/download?format=json`
  - Credential installation: CA certs, client certs, SPIRE join tokens
  - Config generation: Service-specific JSON configs with security settings
- The sysmon checker already has `SecurityConfig` with `mode: mtls|spiffe|none`, so the config structure is ready.

## Goals / Non-Goals
- Goals:
  - Port edge onboarding functionality to Rust for use by sysmon and future Rust checkers.
  - Support both mTLS-only and SPIRE-based onboarding, matching sysmon-osx capabilities.
  - Keep the Rust implementation minimal and focused on checker needs (not pollers/agents).
  - Maintain backwards compatibility with existing manual config workflows.
- Non-Goals:
  - Replace the Go edgeonboarding package (keep it for Go services).
  - Implement the full Admin API for package management (consumers only).
  - Add SPIRE server/agent functionality (only workload API client).

## Decisions (initial)
- Create a new Rust crate `rust/edge-onboarding` with minimal dependencies (`reqwest`, `serde`, `base64`).
- Mirror the Go API where practical: `try_onboard()` as the main entry point returning `Option<OnboardingResult>`.
- Store downloaded credentials in `/var/lib/serviceradar/sysmon/` (or configurable path).
- Generate a merged config file that the existing `Config::from_file()` can load without changes.
- Support environment-based activation: if `ONBOARDING_TOKEN` is set, attempt onboarding before loading the config file.
- Add CLI flags `--mtls`, `--token <TOKEN>`, `--host <HOST>` for explicit mTLS bootstrap (matching sysmon-osx).

## Architecture

```
                          ┌─────────────────────────┐
                          │     Admin UI / CLI      │
                          │  (generates token)      │
                          └───────────┬─────────────┘
                                      │ token
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                         sysmon (Rust)                           │
│  ┌──────────────────┐   ┌──────────────────────────────────┐   │
│  │   CLI Parser     │──▶│   edge-onboarding crate          │   │
│  │  --mtls/env vars │   │  - parse_token()                 │   │
│  └──────────────────┘   │  - download_package()            │   │
│                         │  - install_credentials()         │   │
│                         │  - generate_config()             │   │
│                         └──────────────┬───────────────────┘   │
│                                        │ generated config       │
│                                        ▼                        │
│                         ┌──────────────────────────────────┐   │
│                         │   Config loader                  │   │
│                         │   (existing config.rs)           │   │
│                         └──────────────┬───────────────────┘   │
│                                        │                        │
│                                        ▼                        │
│                         ┌──────────────────────────────────┐   │
│                         │   SysmonService (gRPC server)    │   │
│                         │   with mTLS/SPIFFE credentials   │   │
│                         └──────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Token and Package Format

### Token Format (same as Go)
```
edgepkg-v1:<base64url>

Decoded JSON:
{
  "pkg": "package_id",
  "dl": "download_token",
  "api": "https://core.example.com" (optional)
}
```

### Package Response (from Core API)
```json
{
  "package": {
    "package_id": "...",
    "component_type": "checker",
    "checker_kind": "sysmon",
    "checker_config_json": "{...}",
    ...
  },
  "join_token": "...",
  "bundle_pem": "...",
  "mtls_bundle": {
    "ca_cert_pem": "...",
    "client_cert": "...",
    "client_key": "...",
    "server_name": "...",
    "endpoints": {"poller": "...", "core": "..."}
  }
}
```

## Generated Config Structure
The edge-onboarding crate generates a config compatible with sysmon's existing `Config` struct:

```json
{
  "listen_addr": "0.0.0.0:50083",
  "security": {
    "mode": "mtls",
    "cert_dir": "/var/lib/serviceradar/sysmon/certs",
    "cert_file": "client.crt",
    "key_file": "client.key",
    "ca_file": "ca.crt"
  },
  "poll_interval": 30,
  "filesystems": [{"name": "/", "type": "ext4", "monitor": true}],
  "partition": "sysmon-edge-001"
}
```

## Open Questions
- Should the Rust crate be general-purpose for all Rust checkers, or sysmon-specific initially?
- Do we need async support in the edge-onboarding crate, or can blocking HTTP be acceptable during bootstrap?
- Should we persist the onboarding result (package ID, SPIFFE ID) separately from the generated config for status reporting?

## References
- Go edgeonboarding package: `pkg/edgeonboarding/`
- Go sysmon-osx main: `cmd/checkers/sysmon-osx/main.go`
- mTLS edge onboarding change: `openspec/changes/add-mtls-only-edge-onboarding/`
