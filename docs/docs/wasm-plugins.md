---
sidebar_position: 8
title: Wasm Plugin Checkers
---

# Wasm Plugin Checkers

ServiceRadar supports sandboxed Wasm-based plugins for custom checkers. Plugins are uploaded or imported through the web UI, reviewed for capabilities and allowlists, and then assigned to agents. Agents run plugins in an embedded Wasm runtime with strict resource limits and a capability-based host ABI.

The current edge model is push-based: the agent streams results to `agent-gateway`. External "pull" checkers are not part of the primary architecture; prefer Wasm plugins or first-party collectors that publish into the normal pipelines.

Wasm is also how ServiceRadar ships certain first-party checks. For example, the Dusk checker runs as a Wasm plugin executed by `serviceradar-agent` (it is not a standalone service).

## First-Party Plugin Publication

First-party Wasm plugins now build and publish as signed OCI artifacts instead of ad hoc `dist/` folders.

Current host prerequisites:

- Bazel fetches the pinned `tinygo` release automatically for first-party plugin builds
- `oras` available on the workstation for publish and inspection workflows

Build the canonical bundle artifacts locally with Bazel:

```bash
make build_wasm_plugins
```

Publish, sign, and verify the first-party plugin artifacts only:

```bash
make push_wasm_plugins
```

Or run the repo-wide release publish path, which includes both container images and first-party Wasm plugin OCI artifacts:

```bash
make push_all_release
```

Each published artifact uses an immutable `sha-<git-commit>` tag under a deterministic Harbor repository:

- `registry.carverauto.dev/serviceradar/wasm-plugin-hello-wasm`
- `registry.carverauto.dev/serviceradar/wasm-plugin-axis-camera`
- `registry.carverauto.dev/serviceradar/wasm-plugin-axis-camera-stream`
- `registry.carverauto.dev/serviceradar/wasm-plugin-unifi-protect-camera`
- `registry.carverauto.dev/serviceradar/wasm-plugin-unifi-protect-camera-stream`
- `registry.carverauto.dev/serviceradar/wasm-plugin-dusk-checker`
- `registry.carverauto.dev/serviceradar/wasm-plugin-alienvault-otx-threat-intel`

The bundle payload is a zip archive that contains the canonical import shape:

- `plugin.yaml`
- `plugin.wasm`
- optional sidecars such as `config.schema.json` or `display_contract.json`

Each first-party OCI artifact now carries two trust signals:

- a Cosign signature on the OCI manifest in Harbor
- an additional upload-signature OCI layer whose Ed25519 payload matches the `web-ng` uploaded-package verification policy

That upload-signature sidecar signs the canonical JSON payload:

- `content_hash`: SHA-256 of `plugin.wasm`
- `manifest`: the canonicalized `plugin.yaml` document

Release automation requires these environment variables when publishing first-party Wasm artifacts:

- `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY`: base64, base64url, or hex encoded Ed25519 seed/private key
- `PLUGIN_UPLOAD_SIGNING_KEY_ID`: stable key identifier recorded in the sidecar
- `PLUGIN_UPLOAD_SIGNING_SIGNER`: optional human-readable signer label; defaults to `PLUGIN_UPLOAD_SIGNING_KEY_ID`

You can derive the trusted public key for `web-ng` from the same private key with:

```bash
bazel run //build/wasm_plugins:upload_signature_tool -- public-key
```

Configure that public key in `web-ng` so uploaded-package verification trusts the same release signer:

```bash
export PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS='first-party=<base64-ed25519-public-key>'
```

Inspect a published artifact with `oras`:

```bash
oras manifest fetch registry.carverauto.dev/serviceradar/wasm-plugin-dusk-checker:sha-<commit> --format json
oras pull registry.carverauto.dev/serviceradar/wasm-plugin-dusk-checker:sha-<commit>
```

Wasm plugins are one part of the edge runtime. The agent also runs embedded engines (sync integrations, SNMP polling, discovery/mapping, mDNS) alongside plugins.

## Package Format

Each plugin package is made up of:

- `plugin.yaml` (manifest)
- `plugin.wasm` (Wasm binary)
- optional config schema (JSON Schema)

The control plane stores the manifest and config schema in the database and stores the Wasm binary in the configured package storage backend.

Plugin blob upload and download tokens are transported only in explicit headers or POST bodies. Query-string bearer tokens are not supported.

### Manifest fields

Required fields:

- `id`: stable plugin identifier
- `name`: human-readable name
- `version`: semver string
- `entrypoint`: exported Wasm function name (no args)
- `capabilities`: list of host function capabilities
- `resources`: requested resource budget
- `outputs`: `serviceradar.plugin_result.v1` for checker/status plugins or `serviceradar.camera_stream.v1` for camera streaming plugins

Optional fields:

- `description`
- `runtime`: `wasi-preview1` or `none`
- `permissions`: allowlists for HTTP/TCP/UDP
- `source`: metadata such as repo URL, commit, license
- `schema_version`: UI schema version for config/result contracts (default `1`)
- `display_contract`: supported result widgets (optional)

Example `plugin.yaml`:

```yaml
id: http-check
name: HTTP Check
version: 1.0.0
description: Simple HTTP health check
entrypoint: run_check
runtime: wasi-preview1
outputs: serviceradar.plugin_result.v1
schema_version: 1
capabilities:
  - get_config
  - log
  - submit_result
  - http_request
permissions:
  allowed_domains:
    - api.example.com
  allowed_ports:
    - 443
resources:
  requested_memory_mb: 64
  requested_cpu_ms: 2000
  max_open_connections: 4
display_contract:
  schema_version: 1
  widgets:
    - status_badge
    - stat_card
    - table
    - markdown
    - sparkline
source:
  repo_url: https://github.com/acme/http-check
  commit: 0123456
```

### Config schema

Plugins can include a JSON Schema document describing their runtime configuration. The schema is stored with the package and used for validation in the UI.

Example schema:

```json
{
  "type": "object",
  "properties": {
    "url": {"type": "string"},
    "timeout_ms": {"type": "integer", "minimum": 1}
  },
  "required": ["url"]
}
```

Supported JSON Schema subset:

- Root schema MUST be `type: object`.
- Supported keywords: `type`, `title`, `description`, `default`, `enum`, `minimum`, `maximum`, `minLength`,
  `maxLength`, `pattern`, `format`, `items`, `properties`, `required`, `additionalProperties`.
- Supported formats: `uri`, `email`.
- Array fields MUST define `items`.

## Result Schema (serviceradar.plugin_result.v1)

Plugins submit results as JSON via the `submit_result` host function. The agent validates results and maps them to `GatewayServiceStatus`.

Required fields:

- `status`: `OK`, `WARNING`, `CRITICAL`, or `UNKNOWN`
- `summary`: human-readable summary

Common optional fields:

- `perfdata`: Nagios-style perfdata string
- `metrics`: list of structured metrics
- `labels`: map of label keys/values
- `observed_at`: RFC3339 timestamp (added by agent if omitted)
- `schema_version`: UI schema version for display instructions (default `1`)
- `display`: list of UI widget instructions
  - Each widget may include `layout: full|half` to control grid width in the Services UI.

Example result payload:

```json
{
  "status": "OK",
  "summary": "http 200 in 42ms",
  "perfdata": "latency_ms=42",
  "metrics": [
    {"name": "latency_ms", "value": 42, "unit": "ms"}
  ],
  "labels": {
    "target": "api.example.com"
  },
  "schema_version": 1,
  "display": [
    {"widget": "stat_card", "label": "Latency", "value": "42ms", "tone": "success"},
    {"widget": "table", "data": {"Status": "200", "Region": "us-east-1"}, "layout": "full"}
  ]
}
```

## Capabilities and Permissions

Capabilities are explicitly declared in the manifest and approved during import review. The agent enforces both the capability list and the permission allowlists on every host call.

Common capabilities:

- `get_config`: retrieve assignment parameters
- `log`: emit structured logs
- `submit_result`: send a plugin result payload
- `http_request`: perform HTTP through the host proxy
- `websocket_connect` / `websocket_send` / `websocket_recv` / `websocket_close`
- `camera_media_stream`: send camera media frames through the host media bridge
- `tcp_connect` / `tcp_read` / `tcp_write` / `tcp_close`
- `udp_sendto`

Permissions:

- `allowed_domains`: HTTP hostname allowlist (supports `*` and `*.suffix`)
- `allowed_networks`: CIDR allowlist for TCP/UDP
- `allowed_ports`: TCP/UDP port allowlist

## SDK and Authoring

Plugins compile to `wasm32-wasi` and export a zero-argument entrypoint function that matches the manifest `entrypoint`. Host functions are imported from the `env` module.

SDKs:

- Go SDK: `carverauto/serviceradar-sdk-go`
- Rust SDK: planned (not yet generally available)

### Go (TinyGo) With The ServiceRadar SDK

If you're writing plugins in Go, use the Go SDK repo: `carverauto/serviceradar-sdk-go`.

This gives you a higher-level API over the host ABI:

- `sdk.Execute(func() (*sdk.Result, error) { ... })` for structured execution + error handling
- `sdk.LoadConfig(&cfg)` to decode assignment config JSON
- `sdk.HTTP` / `sdk.TCPDial` / `sdk.UDPSendTo` wrappers (proxy + allowlists enforced by the agent)
- result builders (`sdk.NewResult()`, `sdk.Ok()`, metrics, labels, widgets)

#### Example: HTTP Latency Check (Go SDK)

`main.go`:

```go
//go:build tinygo

package main

import (
	"fmt"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

type Config struct {
	URL    string  `json:"url"`
	WarnMS float64 `json:"warn_ms"`
	CritMS float64 `json:"crit_ms"`
}

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		cfg := Config{URL: "https://example.com/health"}
		_ = sdk.LoadConfig(&cfg)

		resp, err := sdk.HTTP.Get(cfg.URL)
		if err != nil {
			res := sdk.Critical("http request failed")
			res.EmitEvent(sdk.SeverityCritical, "http request failed", "http_request_failed")
			res.RequestImmediateAlert("http_request_failed")
			return res, nil
		}

		latencyMS := float64(resp.Duration.Milliseconds())
		thresholds := sdk.Thresholds(cfg.WarnMS, cfg.CritMS)

		res := sdk.NewResult()
		res.SetSummary(fmt.Sprintf("http %d in %.0fms", resp.Status, latencyMS))
		res.ApplyThresholds(latencyMS, thresholds.Warn, thresholds.Crit)
		res.AddMetric("latency_ms", latencyMS, "ms", thresholds)
		res.AddStatCard("Latency", fmt.Sprintf("%.0fms", latencyMS), toneForStatus(res.Status))

		return res, nil
	})
}

func main() {}

func toneForStatus(status sdk.Status) string {
	switch status {
	case sdk.StatusOK:
		return "success"
	case sdk.StatusCritical:
		return "critical"
	case sdk.StatusWarning:
		return "warning"
	case sdk.StatusUnknown:
		return "neutral"
	default:
		return "success"
	}
}
```

`plugin.yaml`:

```yaml
id: http-check
name: HTTP Check
version: 0.1.0
entrypoint: run_check
outputs: serviceradar.plugin_result.v1
capabilities:
  - get_config
  - log
  - submit_result
  - http_request
resources:
  requested_memory_mb: 64
  requested_cpu_ms: 2000
permissions:
  allowed_domains:
    - example.com
  allowed_ports:
    - 443
```

Build with TinyGo:

```bash
tinygo build -o plugin.wasm -target=wasi ./
```

More examples live in the SDK repo under `examples/`:

- `examples/http-check`
- `examples/tcp-check`
- `examples/udp-check`
- `examples/widgets-check`

### Minimal Host ABI Example (No SDK)

If you want to avoid the SDK, you can use direct host imports.

Minimal TinyGo example:

```go
package main

import "unsafe"

//go:wasmimport env submit_result
func hostSubmitResult(ptr uint32, size uint32) int32

//export run_check
func run_check() {
	payload := []byte(`{"status":"OK","summary":"hello from wasm"}`)
	if len(payload) == 0 {
		return
	}
	ptr := uint32(uintptr(unsafe.Pointer(&payload[0])))
	hostSubmitResult(ptr, uint32(len(payload)))
}

func main() {}
```

Notes:

- Use TinyGo or Rust with a WASI target.
- The entrypoint takes no arguments.
- JSON payloads are required for `submit_result` and `http_request`.
- The agent enforces resource limits (memory, CPU time, max connections).

### HTTP request payload shape

The `http_request` host function expects a JSON request and writes a JSON response:

```json
{
  "method": "GET",
  "url": "https://api.example.com/health",
  "headers": {"accept": "application/json"},
  "timeout_ms": 2000
}
```

Response:

```json
{
  "status": 200,
  "headers": {"content-type": "application/json"},
  "body_base64": "eyJzdGF0dXMiOiJvayJ9",
  "body_encoding": "base64"
}
```

## Upload and Import Workflow

1. Upload or import a plugin package in the admin UI.
2. The package is staged and must be approved.
3. During review, confirm capabilities, permissions, and resource requests.
4. Approved packages can be assigned to agents.
5. Agents download packages only from the ServiceRadar control plane (never directly from GitHub).

### GitHub imports and verification

For GitHub-sourced plugins, the control plane fetches:

- `plugin.yaml`
- `plugin.wasm`
- optional config schema

Commit verification is captured from GitHub. If `PLUGIN_REQUIRE_GPG_FOR_GITHUB=true`, unsigned or unverified commits are rejected during import.

## Deployment Configuration

Wasm packages are served by the web-ng API and stored using a configurable backend. For production, store plugin blobs on persistent storage and back them up with normal platform operations.

Plugin blob authorization is token-gated, but bearer tokens are carried in request headers or POST bodies rather than embedded in request URLs.

### AlienVault OTX Threat Intel

ServiceRadar ships a first-party `alienvault-otx-threat-intel` Wasm plugin for edge-side OTX collection. Use **Settings -> Networks -> Threat Intel** to assign the approved package to an agent, set the OTX base URL, page size, timeout, and a secret reference for the API key. The key is used by the plugin through the normal secret-ref flow and is not displayed back in the UI.

The edge plugin needs outbound HTTPS egress to the configured OTX host, normally `otx.alienvault.com:443`. Review the package permissions during approval before assigning it to customer edge agents or networks that can reach SIEM-adjacent systems.

Core-hosted OTX sync is also available for deployments that prefer the control plane to poll OTX directly. Configure the core worker with environment variables on `core-elx`:

- `SERVICERADAR_OTX_API_KEY` or `SERVICERADAR_OTX_API_KEY_FILE`
- `SERVICERADAR_OTX_BASE_URL` (default behavior uses `https://otx.alienvault.com`)
- `SERVICERADAR_OTX_PAGE_SIZE`
- `SERVICERADAR_OTX_TIMEOUT_MS`
- `SERVICERADAR_OTX_MAX_INDICATORS`
- `SERVICERADAR_OTX_MAX_RETRIES`
- `SERVICERADAR_OTX_BACKOFF_MS`
- `SERVICERADAR_OTX_MODIFIED_SINCE`
- `SERVICERADAR_OTX_PARTITION`

Prefer the `*_FILE` form for Kubernetes secrets. Rotate OTX keys through the secret backend or Kubernetes secret, then restart or roll the affected pod so runtime config is refreshed. After rotation, use **Sync Now** on the Threat Intel settings page and verify Sync Health shows a fresh successful run. The sync status records skipped unsupported types such as domains or URLs separately from IP/CIDR indicators, because current NetFlow matching only uses IP/CIDR data.

### Filesystem backend (default)

- Storage path: `/var/lib/serviceradar/plugin-packages`
- Configure with:
  - `PLUGIN_STORAGE_BACKEND=filesystem`
  - `PLUGIN_STORAGE_PATH=/var/lib/serviceradar/plugin-packages`
  - `PLUGIN_STORAGE_SIGNING_SECRET` (shared with core for signed plugin blob tokens)

Docker:

- Mount a volume to `/var/lib/serviceradar/plugin-packages` in the `web-ng` container.

Kubernetes:

- Mount a PVC at `/var/lib/serviceradar/plugin-packages` for the `web-ng` deployment.

Core plugin blob delivery:

- `PLUGIN_STORAGE_PUBLIC_URL` (base URL for web-ng, e.g. `https://staging.serviceradar.cloud`)
- `PLUGIN_STORAGE_SIGNING_SECRET` (must match web-ng)
- `PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS` (default 86400)
- Agents receive a plain plugin blob endpoint plus a separate short-lived token, so plugin config does not contain a tokenized URL.

### JetStream object store

Set:

- `PLUGIN_STORAGE_BACKEND=jetstream`
- `PLUGIN_STORAGE_BUCKET=serviceradar_plugins`
- `PLUGIN_STORAGE_JS_MAX_BUCKET_BYTES`
- `PLUGIN_STORAGE_JS_MAX_CHUNK_BYTES`
- `PLUGIN_STORAGE_JS_REPLICAS`
- `PLUGIN_STORAGE_JS_STORAGE` (`file` or `memory`)
- `PLUGIN_STORAGE_JS_TTL_SECONDS`

This backend requires NATS JetStream to be available to web-ng.

### GitHub access and verification policy

- `GITHUB_TOKEN` or `GH_TOKEN` for private repos
- `PLUGIN_REQUIRE_GPG_FOR_GITHUB=true` to reject unverified commits
- `PLUGIN_ALLOW_UNSIGNED_UPLOADS=false` to require signatures for uploads

## Operational Tips

- Keep per-agent engine limits conservative and override down in assignments if needed.
- Use the Settings -> Agent capacity view to confirm headroom before assignments.
- Store plugin source details in the manifest `source` section for auditability.
