---
sidebar_position: 8
title: Wasm Plugin Checkers
---

# Wasm Plugin Checkers

ServiceRadar supports sandboxed Wasm-based plugins for custom checkers. Plugins are uploaded or imported through the web UI, reviewed for capabilities and allowlists, and then assigned to agents. Agents run plugins in an embedded Wasm runtime with strict resource limits and a capability-based host ABI.

Use Wasm plugins for new custom checks. For legacy gRPC checkers, see [Custom Checkers (gRPC)](./custom-checkers.md).

## Package Format

Each plugin package is made up of:

- `plugin.yaml` (manifest)
- `plugin.wasm` (Wasm binary)
- optional config schema (JSON Schema)

The control plane stores the manifest and config schema in the database and stores the Wasm binary in the configured package storage backend.

### Manifest fields

Required fields:

- `id`: stable plugin identifier
- `name`: human-readable name
- `version`: semver string
- `entrypoint`: exported Wasm function name (no args)
- `capabilities`: list of host function capabilities
- `resources`: requested resource budget
- `outputs`: must be `serviceradar.plugin_result.v1`

Optional fields:

- `description`
- `runtime`: `wasi-preview1` or `none`
- `permissions`: allowlists for HTTP/TCP/UDP
- `source`: metadata such as repo URL, commit, license

Example `plugin.yaml`:

```yaml
id: http-check
name: HTTP Check
version: 1.0.0
description: Simple HTTP health check
entrypoint: run_check
runtime: wasi-preview1
outputs: serviceradar.plugin_result.v1
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
  }
}
```

## Capabilities and Permissions

Capabilities are explicitly declared in the manifest and approved during import review. The agent enforces both the capability list and the permission allowlists on every host call.

Common capabilities:

- `get_config`: retrieve assignment parameters
- `log`: emit structured logs
- `submit_result`: send a plugin result payload
- `http_request`: perform HTTP through the host proxy
- `tcp_connect` / `tcp_read` / `tcp_write` / `tcp_close`
- `udp_sendto`

Permissions:

- `allowed_domains`: HTTP hostname allowlist (supports `*` and `*.suffix`)
- `allowed_networks`: CIDR allowlist for TCP/UDP
- `allowed_ports`: TCP/UDP port allowlist

## SDK and Authoring

Plugins compile to `wasm32-wasi` and export a zero-argument entrypoint function that matches the manifest `entrypoint`. Host functions are imported from the `env` module.

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

### Filesystem backend (default)

- Storage path: `/var/lib/serviceradar/plugin-packages`
- Configure with:
  - `PLUGIN_STORAGE_BACKEND=filesystem`
  - `PLUGIN_STORAGE_PATH=/var/lib/serviceradar/plugin-packages`

Docker:

- Mount a volume to `/var/lib/serviceradar/plugin-packages` in the `web-ng` container.

Kubernetes:

- Mount a PVC at `/var/lib/serviceradar/plugin-packages` for the `web-ng` deployment.

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
