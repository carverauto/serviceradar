## Context
ServiceRadar currently relies on fixed checkers (SNMP, ICMP, Sysmon) or external gRPC checkers. Issue #2487 proposes a Wasm-based plugin system to let users upload custom checks through the UI and distribute them to agents safely. The system must support constrained, unreliable edge environments while producing results that align with existing Gateway/Core ingestion (Nagios/Zabbix-style status + perfdata).

## Goals / Non-Goals
- Goals:
  - Provide a secure, capability-based sandbox for custom checks.
  - Support a first-class plugin packaging and distribution workflow.
  - Standardize results output with clear status semantics and perfdata.
  - Keep agent builds portable (no CGO) and resource-bounded.
  - Support both filesystem and NATS object storage for package hosting.
- Non-Goals:
  - Replace existing gRPC checkers or sweep jobs.
  - Provide full WASI filesystem or raw socket access to plugins.
  - Introduce multitenancy or per-customer routing modes.

## Decisions
- Decision: Use wazero in the Go agent.
  - Why: Pure Go, zero CGO, cross-arch friendly, supports host function gating and memory limits.
  - Alternatives considered: Wasmtime (CGO), Lua, embedded JS (weaker sandbox, harder to constrain).

- Decision: Plugin package is a single archive containing `plugin.yaml` + `.wasm` (plus optional assets).
  - Required files: `plugin.yaml`, `plugin.wasm`.
  - Optional files: `README.md`, `schema.json` (config schema), `icon.svg`, `signature.json`, `sbom.json`.
  - `plugin.yaml` fields (v1):
    - `id`, `name`, `version`, `description`, `entrypoint` (e.g., `run_check`)
    - `runtime` (e.g., `wasi-preview1` or `none`)
    - `capabilities` (host functions requested)
    - `permissions` (allowed_domains, allowed_networks, allowed_ports)
    - `resources` (max_memory_mb, max_cpu_ms, max_open_connections)
    - `outputs` (schema version: `serviceradar.plugin_result.v1`)
    - `source` (repo URL, commit, license)

- Decision: Control plane stores packages via a pluggable backend.
  - Default: filesystem path configured in web-ng (Docker volume or k8s PVC).
  - Optional: NATS JetStream object store for replication/edge caching.
  - Web-ng serves packages over its API with mTLS/JWT auth; agents receive a signed download URL plus hash.

- Decision: Agent config includes explicit plugin assignments.
  - `AgentConfigResponse` gains a `plugin_config` field with assignments (id, version, package ref, schedule, timeout, permissions override, config blob).
  - Config version changes when plugin assignments or package refs change.

- Decision: Results output uses a Nagios-style schema with structured metrics.
  - `PluginResult` JSON (schema `serviceradar.plugin_result.v1`) includes:
    - `status`: `OK | WARNING | CRITICAL | UNKNOWN`
    - `summary`: one-line string suitable for UI/alerts
    - `details`: optional long text
    - `perfdata`: optional string in Nagios perfdata format
    - `metrics`: list of structured metrics (name, value, unit, warn, crit, min, max)
    - `labels`: key/value context
    - `observed_at`: RFC3339 timestamp
  - Mapping to `GatewayServiceStatus`:
    - `available = (status == OK || status == WARNING)`
    - `message = PluginResult JSON`
    - `response_time` computed by agent runtime

- Decision: Capability-based host functions only.
  - Required functions: `get_config`, `log`, `submit_result`.
  - Network functions are proxy-based: `http_request`, `tcp_connect/read/write/close`, `udp_sendto`.
  - Agent enforces allowlists and global timeouts; plugins never touch raw sockets.

- Decision: Package integrity is enforced via hash + signature.
  - Web-ng signs the package hash with a deployment key.
  - Agents verify signature before execution and cache by hash.

## Risks / Trade-offs
- Risk: Plugin output schema mismatch with existing UI expectations → Mitigation: strict schema validation and compatibility adapters in gateway/core.
- Risk: Storage backend complexity (filesystem vs JetStream) → Mitigation: keep JetStream optional behind a config flag and preserve API contract.
- Risk: Resource abuse → Mitigation: enforce memory/CPU/timeouts, cap connections, and cleanup handles on completion.

## Migration Plan
1. Add Ash resources + migrations for plugin packages and assignments.
2. Implement storage backend and package-serving API in web-ng.
3. Extend proto/config pipeline to deliver plugin assignments.
4. Embed wazero runtime + host function ABI in agent.
5. Map plugin results into `GatewayServiceStatus` and surface in UI.
6. Document packaging, SDKs, and deployment.

## Open Questions
- Should phase 1 include JetStream object storage or defer to filesystem-only?
- Do we need a separate `plugin-results` stream for large outputs?
- What is the default mapping for `WARNING` in UI/alerting (degraded vs available)?
- Should we provide first-party SDKs for TinyGo + Rust in-repo or as external repos?
