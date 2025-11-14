# Edge Onboarding Integration Status

## Overview

We've successfully integrated the edge onboarding library into ServiceRadar services. Services can now be onboarded with just an environment variable - no more shell scripts!

## ✅ Completed Work

### Phase 1: Core Library (Complete)
- ✅ Created `pkg/edgeonboarding/` package with complete onboarding flow
- ✅ Deployment type detection (Docker, Kubernetes, bare-metal)
- ✅ Component-specific SPIRE configuration
- ✅ Service configuration generation
- ✅ Package download and validation (HTTP JSON deliver + structured token parsing)
- ✅ Comprehensive documentation (README.md)

### Phase 2: Service Integration (Complete)
- ✅ Created `integration.go` helper for services
- ✅ Integrated into `cmd/poller/main.go`
- ✅ Integrated into `cmd/agent/main.go`
- ✅ Integrated into `cmd/checkers/snmp/main.go` (example for all checkers)

## 📦 Recent Updates (Nov 2025)
- Core’s `/api/admin/edge-packages/{id}/download` endpoint now serves JSON responses when `?format=json` or `Accept: application/json` is supplied, so bootstrap clients can pull sanitized metadata plus SPIRE join material without touching tarballs.
- `pkg/edgeonboarding/download.go` performs the full HTTP flow (token parsing → Core URL resolution via structured tokens / `CORE_API_URL` → JSON deliver → package validation) and is exercised via `pkg/edgeonboarding/download_test.go`.
- Structured `edgepkg-v1:<payload>` tokens are parsed/encoded by `pkg/edgeonboarding/token.go`, paving the way for single-string onboarding once the UI/CLI emits them by default.
- The admin UI now exposes a copy-to-clipboard edgepkg-v1 onboarding token (and `serviceradar-cli edge-package-token` mirrors it) so operators simply export `ONBOARDING_TOKEN` instead of juggling `EDGE_PACKAGE_ID`/`CORE_API_URL`.
- `serviceradar-cli` gained `edge package create/list/show/download/revoke/token`, mirroring the UI’s package workflow with JSON or tabular output. The download command now supports `--format=json` for audit logs, and `edge package show --reissue-token` emits fresh `edgepkg-v1` strings without touching the UI.
- Offline hosts can set `ONBOARDING_PACKAGE=/path/to/archive.tar.gz`. The bootstrapper validates the tarball (metadata/join-token/bundle) and hydrates SPIRE + config without contacting Core, which means air-gapped installs now follow the exact same binary flow as online pollers/agents.

## 🚀 How to Use

### Simple Deployment (Just Environment Variables)

```bash
# Poller
docker run \
  -e ONBOARDING_TOKEN=your-token-here \
  -e KV_ENDPOINT=23.138.124.23:50057 \
  ghcr.io/carverauto/serviceradar-poller:latest

# Agent
docker run \
  -e ONBOARDING_TOKEN=your-token-here \
  -e KV_ENDPOINT=23.138.124.23:50057 \
  ghcr.io/carverauto/serviceradar-agent:latest

# Checker
docker run \
  -e ONBOARDING_TOKEN=your-token-here \
  -e KV_ENDPOINT=23.138.124.23:50057 \
  ghcr.io/carverauto/serviceradar-snmp-checker:latest
```

### Using Command-Line Flags

```bash
./serviceradar-poller \
  --onboarding-token your-token-here \
  --kv-endpoint 23.138.124.23:50057
```

### Backwards Compatibility

If no onboarding token is provided, services fall back to traditional config:

```bash
# Still works the old way
./serviceradar-poller --config /etc/serviceradar/poller.json
```

## 🔴 TODO: Remaining Work

### High Priority

#### 1. Complete SPIRE Configuration Generation
**Files**:
- `pkg/edgeonboarding/spire.go:generateNestedSPIREServerConfig()`
- `pkg/edgeonboarding/spire.go:generateNestedSPIREAgentConfig()`

Currently generates placeholder configs. Needs real HCL configuration:

```hcl
# Example SPIRE server config needed:
server {
  bind_address = "0.0.0.0"
  bind_port = "8081"
  trust_domain = "carverauto.dev"
  data_dir = "/var/lib/serviceradar/spire/server-data"
  log_level = "INFO"
}

plugins {
  DataStore "sql" {
    plugin_data {
      database_type = "sqlite3"
      connection_string = "/var/lib/serviceradar/spire/server-data/datastore.sqlite3"
    }
  }

  NodeAttestor "join_token" {
    plugin_data {}
  }

  KeyManager "disk" {
    plugin_data {
      keys_path = "/var/lib/serviceradar/spire/server-data/keys.json"
    }
  }

  UpstreamAuthority "spire" {
    plugin_data {
      server_address = "23.138.124.18"
      server_port = "18081"
    }
  }
}
```

#### 2. Wire docs/UI to the JSON downloader
**Files**: `docs/docs/edge-onboarding.md`, `web/src/components/Admin/ConfigForms/*`, onboarding runbooks

The HTTP bootstrapper expects operators to provide the Core URL (via token or `CORE_API_URL`). Update the docs and the admin UI copy to explain the JSON download flow, highlight the new environment variables, and steer users away from tarball/manual scripts except for offline installs.

### Medium Priority

#### 3. Implement Credential Rotation
**File**: `pkg/edgeonboarding/bootstrap.go:Rotate()`

```go
func Rotate(ctx context.Context, storagePath string, log logger.Logger) error {
    // 1. Read current SPIRE state from storage
    // 2. Check if credentials are expiring (TTL < threshold)
    // 3. Request new join token from upstream SPIRE
    // 4. Update SPIRE configuration
    // 5. Trigger SPIRE reload/restart
    // 6. Verify new credentials work
}
```

Should be called periodically (e.g., via cron or background goroutine).

#### 4. Add Integration Tests

```bash
# Test files needed:
pkg/edgeonboarding/bootstrap_test.go
pkg/edgeonboarding/download_test.go
pkg/edgeonboarding/deployment_test.go
pkg/edgeonboarding/spire_test.go
pkg/edgeonboarding/config_test.go
pkg/edgeonboarding/integration_test.go
```

#### 5. Integrate into Other Checkers

Apply the same pattern to:
- `cmd/checkers/dusk/main.go`
- `cmd/checkers/sysmon-vm/main.go`
- Any other checker services

### Low Priority

#### 6. Address Resolution from Package Metadata
**File**: `pkg/edgeonboarding/deployment.go:getAddressForDeployment()`

Needs to:
- Parse metadata JSON from package
- Extract service addresses based on deployment type
- Return appropriate address (LoadBalancer IP for Docker, DNS for k8s)

#### 7. Storage Path Detection
**File**: `pkg/edgeonboarding/bootstrap.go:detectDefaultStoragePath()`

Needs to:
- Check if running as root (can use `/var/lib/serviceradar`)
- Fall back to `./data` for non-root
- Check for write permissions

#### 9. Documentation Updates
- Update main edge onboarding docs
- Add migration guide for existing deployments
- Create video/demo of onboarding process
- Update deployment guides

## 🔜 Next Focus

- **SPIRE + metadata polish** – We still need real HCL emitters in `generateNestedSPIREServerConfig`/`generateNestedSPIREAgentConfig` plus deployment-aware address helpers so Docker pollers automatically pivot to LoadBalancer IPs.
- **Rust/sysmon parity** – Capture the requirements for a Rust bootstrap crate that mirrors the Go helper so `cmd/checkers/sysmon` accepts the exact same `--onboarding-token`/`--kv-endpoint` or `ONBOARDING_PACKAGE` flow as Go services.
- **Docs + UI alignment** – The admin UI already builds `edgepkg-v1` strings and now references the CLI; continue tightening `docs/docs/edge-onboarding.md`, `docs/docs/docker-setup.md`, and the admin copy so the JSON download/ONBOARDING_PACKAGE path is the primary workflow.

## 🎯 Quick Wins

These can be done quickly for immediate value:

### 1. Extract Core Endpoint from Package Metadata
Instead of requiring Core endpoint in config, extract it from package:

```go
func (b *Bootstrapper) GetCoreEndpoint() string {
    if b.cfg.CoreEndpoint != "" {
        return b.cfg.CoreEndpoint
    }
    // Extract from package metadata
    metadata, _ := b.parseMetadata()
    if addr, ok := metadata["core_address"].(string); ok {
        return b.getAddressForDeployment("core", addr)
    }
    return ""
}
```

### 2. Add Validation for Required Metadata Fields
Add early validation to catch missing metadata:

```go
func (b *Bootstrapper) validatePackageMetadata() error {
    metadata, err := b.parseMetadata()
    if err != nil {
        return err
    }

    required := []string{"core_address", "kv_address"}
    for _, key := range required {
        if metadata[key] == "" {
            return fmt.Errorf("required metadata %q not found", key)
        }
    }
    return nil
}
```

### 3. Environment Variable Fallbacks
Allow more environment variables for flexibility:

```go
// In TryOnboard():
token := os.Getenv("ONBOARDING_TOKEN")
if token == "" {
    token = os.Getenv("SR_ONBOARDING_TOKEN")
}

kvEndpoint := os.Getenv("KV_ENDPOINT")
if kvEndpoint == "" {
    kvEndpoint = os.Getenv("SR_KV_ENDPOINT")
}
```

## 🗂️ Workstream Implementation Plan

### 1. Documentation & UX alignment
- Merge the Compose SPIFFE explanation plus the Kong profile steps into `docs/docs/docker-setup.md` so “clone → docker compose up -d → docker compose up -d nginx kong” is obvious.
- Keep `docs/docs/edge-onboarding.md` and `docs/docs/edge-agent-onboarding.md` pointed at Admin → Edge Packages while we work through the Settings relocation; highlight tokens + CLI as the canonical bootstrap, with a short offline appendix.
- Link the UI’s “copy onboarding command” helpers to the new CLI verbs so the in-product experience matches the doc.

### 2. Finish the Go bootstrapper (`pkg/edgeonboarding`)
- **Package delivery:** Wire `downloadPackage` to honor env overrides, parse metadata, and store helper artifacts under `/var/lib/serviceradar`.
- **Offline mode:** `ONBOARDING_PACKAGE` already loads tarballs from disk—continue tightening validation and add checksum verification before writing to disk.
- **SPIRE config:** Replace the placeholder HCL emitters with real nested server/agent configs that mirror the Compose templates (datastore, upstream authority, selectors).
- **Address/metadata handling:** Teach `getAddressForDeployment`/`getSPIREAddressesForDeployment` to pick the right endpoints for Docker vs. k8s vs. bare metal based on metadata hints.
- **Rotation & status:** Fill in `Rotate()`/`GetRotationInfo()` so services and the CLI can surface certificate health.
- **Testing:** Expand the `pkg/edgeonboarding/*_test.go` coverage for metadata parsing, SPIRE config generation, download error handling, and offline archive validation.

### 3. Service integration (Go)
- Ensure every Go binary that calls `edgeonboarding.TryOnboard` still loads legacy configs when no token/package is present.
- Consider a shared helper (maybe `pkg/edgeonboarding/cmd/bootstrap`) for init containers or provisioning scripts that need to pre-download packages for air-gapped installs.
- Add smoke tests for poller, agent, sysmon-vm, mapper, sync, etc., so we know the onboarding path hasn’t regressed.

### 4. Service integration (Rust)
- Build a Rust crate (`rust/edge-onboarding`) mirroring the Go bootstrapper—accepts `ONBOARDING_TOKEN` or `ONBOARDING_PACKAGE`, calls the Core deliver API, and writes the same config layout.
- Update `cmd/checkers/sysmon/src/main.rs` with `--onboarding-token`, `--kv-endpoint`, `--package` flags plus env fallbacks and call the bootstrapper before `config_bootstrap::Bootstrap`.
- Log the SPIFFE ID on success so operators get the same confirmation they see in the Go services.

### 5. UI/API polish
- Make Edge onboarding reachable from Settings (breadcrumb + nav), communicate the parent hierarchy, and surface “Copy onboarding command” helpers for poller/agent/checker components.
- Extend the CLI subcommands (`edge package create/list/show/download`) as the UX evolves (e.g., include checker metadata, parents, and events in JSON mode).
- For offline installs, add an explicit download button per component that delivers the same tarball that the CLI emits.

### 6. Validation & monitoring
- Build integration tests (potentially in `docker/compose/edge-e2e`) that issue a package, start poller/agent/checker with `ONBOARDING_TOKEN` or `ONBOARDING_PACKAGE`, and assert activation in Core.
- Emit bootstrapper metrics/logs for download errors, expired tokens, SPIRE failures, and offline package validation so support can diagnose issues quickly.

### 7. Rolling the docs once code ships
- Replace the manual `edge-poller.env` steps in `docs/docs/edge-onboarding.md` with the token/CLI instructions, leaving tarball edits in the offline appendix.
- Add a troubleshooting appendix for limited-connectivity scenarios (e.g., when the checker must import a package via `--package`).

## 🛠️ CLI Reference

`serviceradar-cli` mirrors the Admin → Edge Packages workflow:

- `serviceradar-cli edge package create` — Issue a package (`--component-type poller|agent|checker[:kind]`, `--label`, selectors, TTLs, notes) and emit a ready-to-export `edgepkg-v1:` token plus JSON output when `--output=json` is set.
- `serviceradar-cli edge package list` — Summaries with ID, component type, status, expiry, optional filters (`--status`, `--component-type`, `--poller-id`, `--parent-id`), and JSON output for automation.
- `serviceradar-cli edge package show` — Detailed view (timestamps, selectors, metadata). Add `--reissue-token --download-token <token>` to mint a new structured onboarding token without visiting the UI.
- `serviceradar-cli edge package download` — Fetch artifacts as a tarball (default) or JSON (`--format=json`). Tarballs are what operators pass to `ONBOARDING_PACKAGE`; JSON is great for audit trails or copying join/download tokens into password managers.
- `serviceradar-cli edge package revoke` / `edge package token` — Existing revoke/token helpers remain, now reachable via the nested `edge package` dispatcher.

All commands live under `pkg/cli/edge_onboarding.go`, share auth/TLS flags with the rest of the CLI, and default to human-friendly output while offering structured JSON for scripting.

## 📦 Offline Package Semantics

- Set `ONBOARDING_PACKAGE=/path/to/edge-package.tar.gz` on hosts without Core access. The bootstrapper validates `metadata.json`, `spire/upstream-join-token`, and `spire/upstream-bundle.pem`, hydrates SPIRE/config under `/var/lib/serviceradar`, and proceeds without an HTTP download.
- Recommended tar layout (produced by Core + the CLI):
  ```
  edge-package-<id>.tar.gz
    ├── metadata.json
    ├── kv/seed.json
    ├── spire/server/server.conf
    ├── spire/server/server.key
    ├── spire/agent/agent.conf
    ├── spire/agent/bootstrap.crt
    └── README.offline.md
  ```
- `metadata.json` must include `core_address`, `kv_address`, `datasvc_endpoint`, `spire_upstream_address`, deployment hints, and checker/agent metadata so `getAddressForDeployment` can choose the right endpoint automatically.
- Follow-up: add checksum verification (and a CLI `--verify` flag) so sneakernet copies are validated before touching disk. If validation fails, we’ll instruct operators to re-run `serviceradar-cli edge package download --verify`.

## 🧪 Testing Plan

### Manual Testing Steps

1. **Create onboarding package via UI/CLI**
   ```bash
   # TODO: Add CLI command
   serviceradar-cli edge create-package --name "Test Poller" --type poller
   ```

2. **Start poller with token**
   ```bash
   docker run \
     -e ONBOARDING_TOKEN=<token> \
     -e KV_ENDPOINT=23.138.124.23:50057 \
     ghcr.io/carverauto/serviceradar-poller:latest
   ```

3. **Verify**
   - Config files generated in `/var/lib/serviceradar/config/`
   - SPIRE credentials in `/var/lib/serviceradar/spire/`
   - Service starts successfully
   - Service connects to Core and reports status

### Automated Testing

```bash
# Unit tests
go test ./pkg/edgeonboarding/...

# Integration tests (requires Core + KV running)
go test ./pkg/edgeonboarding/... -tags=integration

# E2E tests (full stack)
./scripts/test-edge-onboarding-e2e.sh
```

## 📊 Success Metrics

- ✅ Services can start with just `ONBOARDING_TOKEN` + `KV_ENDPOINT`
- ✅ No shell scripts needed
- ✅ No manual kubectl commands
- ✅ No manual ConfigMap updates
- ⏳ Works across Docker, k8s, and bare-metal deployments
- ⏳ Automatic poller registration (no Core restart)
- ⏳ Complete SPIRE configuration generated
- ⏳ Credential rotation working

## 🔗 Related

- **GitHub Issue**: #1915
- **bd Issue**: serviceradar-57
- **Branch**: `1915-create-common-onboarding-library-to-eliminate-edge-deployment-friction`
- **Documentation**: `pkg/edgeonboarding/README.md`
- **Friction Points**: `docker/compose/edge-e2e/FRICTION_POINTS.md`

## 📝 Notes

### Key Design Decisions

1. **KV (datasvc) is source of truth** - All dynamic config from KV, not ConfigMaps
2. **Bootstrap configs are sticky** - Only KV/Core addresses in static files
3. **Deployment-aware** - Auto-detects environment and uses correct addresses
4. **Backwards compatible** - Falls back to traditional config if no token
5. **Self-contained** - Library has no external dependencies except standard services

### Migration Path

For existing edge deployments:

1. Update to version with onboarding library
2. Create onboarding package via UI
3. Set `ONBOARDING_TOKEN` and `KV_ENDPOINT` environment variables
4. Remove old shell scripts
5. Start service - onboarding happens automatically

Old deployments continue to work without changes (backwards compatible).
