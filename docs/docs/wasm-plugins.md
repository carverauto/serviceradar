---
sidebar_position: 8
title: Wasm Plugins
---

# Wasm Plugins

ServiceRadar supports sandboxed WebAssembly (Wasm) plugins for custom checkers and integrations. Plugins are uploaded or imported through the web UI, reviewed for capabilities and allowlists, and then assigned to agents. Agents run plugins in an embedded Wasm runtime (`wazero`) with strict resource limits and a capability-based host ABI.

This page is an operator-facing conceptual overview. For the full plugin SDK and authoring reference — manifest fields, config and result schemas, the host ABI, code examples, and build instructions — see the developer portal at [developer.serviceradar.cloud](https://developer.serviceradar.cloud).

## Why Wasm Plugins

Wasm plugins let ServiceRadar extend its checking capabilities without trusting arbitrary native code on the edge:

- **Sandboxed.** Each plugin runs inside an isolated Wasm runtime. It cannot touch the host filesystem, network, or processes directly.
- **Capability-based.** A plugin can only do what its manifest explicitly declares and an operator explicitly approves. Every host call is mediated and enforced.
- **Resource-limited.** The agent enforces per-plugin budgets for memory, CPU time, and open connections.
- **Portable.** Plugins compile to a single `wasm32-wasi` artifact that runs identically across agent platforms.

The current edge model is push-based: the agent streams results to `agent-gateway`. External "pull" checkers are not part of the primary architecture; prefer Wasm plugins or first-party collectors that publish into the normal pipelines.

Wasm is also how ServiceRadar ships certain first-party checks. For example, the Dusk checker runs as a Wasm plugin executed by `serviceradar-agent` rather than as a standalone service. Wasm plugins are one part of the edge runtime — the agent also runs embedded engines (sync integrations, SNMP polling, discovery/mapping, mDNS) alongside plugins.

## Package Format

Each plugin package is made up of:

- `plugin.yaml` — the manifest (plugin identity, capabilities, permissions, resource requests)
- `plugin.wasm` — the compiled Wasm binary
- optional sidecars such as a config JSON Schema, result display contract, or
  log/event signal display contracts

The control plane stores the manifest and config schema in the database and stores the Wasm binary in the configured package storage backend.

The exact manifest fields, the supported config JSON Schema subset, and the `serviceradar.plugin_result.v1` result schema are documented in full on the [developer portal](https://developer.serviceradar.cloud).

Plugins that emit OCSF events or OTEL-style logs must also declare
`signal_schemas` in `plugin.yaml`. Each signal schema points at a payload JSON Schema
and a declarative display contract shipped with the same package version. See
[Telemetry Display Contracts](./telemetry-display-contracts.md) for the operator
review model and fallback behavior.

Use the `emit_telemetry` capability for first-class plugin events, logs, or
metric batches that should be ingested independently of the check result. Metric
time-series must use the canonical `serviceradar.metric.v1` telemetry payload;
`serviceradar.plugin_result.v1` metrics are no longer a metric ingestion path.
Check-scoped annotations can still use the `events` field in
`serviceradar.plugin_result.v1`, but those events are coupled to `submit_result`
and are not a streaming telemetry surface.

## Gateway-Mediated Artifacts

Wasm plugins can produce more than small health-check results. A plugin that
needs durable snapshots, advisory feed batches, SBOM evidence, or other large
artifacts should use the host SDK artifact APIs. Those calls are logical
ServiceRadar operations such as opening an artifact, writing chunks, committing
with metadata, aborting, and reporting the committed object identity in the
plugin result.

The plugin never receives NATS JetStream Object Store credentials and never talks
to web-ng directly. The agent brokers the host call through agent-gateway, and
agent-gateway writes through the normal internal object-storage path. Native
add-ons follow the same boundary. Choose a native add-on only when the producer
needs OS or runtime capabilities outside the Wasm sandbox, not because it needs
durable artifact staging.

For vulnerability or threat-intelligence feeds, the producer is responsible for
provider-specific download, schema validation, checksum verification, archive
handling, and normalization. The result submitted to ServiceRadar should be the
generic advisory batch contract plus snapshot provenance. Core stores and matches
that generic contract; it does not own CISA, NVD, VulnCheck, OSV, or other
provider parsers.

Scheduled advisory or diagnostic producers declare `producer_schedules` in the
plugin package manifest. ServiceRadar persists those declarations, renders
operator-owned settings for cadence, credentials, and assignment, and dispatches
due runs through the existing agent commandbus with `plugin.run_action`. The
scheduled invocation payload uses `serviceradar.producer_schedule_run.v1`; the
plugin remains responsible for provider-specific fetch and normalization.
Operator-selected credentials are converted into scoped `credential_brokers` in
the command payload. Raw `credential_refs` remain platform state and are not sent
directly to the agent.

```yaml
capabilities:
  - get_config
  - submit_result
  - http_request
  - artifact-staging:v1
  - advisory-feed:v1
  - producer-schedule:v1

producer_schedules:
  - schedule_id: daily_advisory_refresh
    label: Refresh advisory feed
    action_id: advisory.refresh
    command_type: plugin.run_action
    default_cadence_seconds: 86400
    min_cadence_seconds: 3600
    max_cadence_seconds: 2592000
    jitter_seconds: 120
    dispatch_scope: assignment
    payload_template:
      feed_key: primary
```

## Capability and Permission Model

Capabilities and permissions are the core of the plugin security model. They are declared in the manifest and approved during import review. The agent enforces both the capability list and the permission allowlists on every host call.

- **Capabilities** name the host functions a plugin is allowed to call — for example, retrieving its config, writing agent runtime logs, emitting first-class telemetry, submitting a result, making HTTP requests, or opening TCP/UDP connections. A plugin cannot call a host function it did not declare.
- **Permissions** are the allowlists that scope those capabilities — for example, the set of HTTP hostnames, CIDR networks, and ports a plugin may reach. Network access is denied by default and only widened by explicit allowlist entries.

Because capabilities and permissions are visible in the manifest, reviewers can see a plugin's full blast radius before approving it. Always confirm them during import review, especially for plugins assigned to customer edge agents or networks that can reach sensitive systems.

The full list of capability names and permission keys lives on the [developer portal](https://developer.serviceradar.cloud).

## SDKs and Authoring

Plugins compile to `wasm32-wasi` and export a zero-argument entrypoint that matches the manifest. ServiceRadar publishes SDKs that provide a higher-level API over the host ABI so you do not have to work with raw host imports.

See the [SDKs & Plugin Development](./sdks.md) overview for a summary of the available SDKs, and the [developer portal](https://developer.serviceradar.cloud) for the complete authoring reference, code examples, and build instructions.

## Upload and Import Workflow

The plugin lifecycle is operator-facing and gated by an approval step:

1. Upload or import a plugin package in the admin UI.
2. The package is staged and must be approved before it can be used.
3. During review, confirm the requested capabilities, permissions, and resource budget.
4. Approved packages can be assigned to agents.
5. Agents download packages only from the ServiceRadar control plane — never directly from GitHub.

Plugin blob upload and download tokens are transported only in explicit headers or POST bodies. Query-string bearer tokens are not supported.

Assigned health-result plugins, including first-party plugins such as UniFi and AlienVault OTX, appear in `/services` with a stable `plugin` service identity. When an assignment is created, the control plane seeds a pending service row; the next agent-reported plugin result updates that row with the plugin status and summary.

### Authenticated partition binding and legacy recovery

An operator selects an **agent**, not a partition. Before an assignment is saved,
ServiceRadar displays the agent's **Authenticated partition** when a live mTLS
control session can prove it. The server derives the assignment partition from
that session again when it writes the assignment. Do not expect a partition
drop-down or attempt to add `partition_id` to an API request: an operator-supplied
value is never authority to route a plugin into an edge partition.

If the agent is offline, enrolled in more than one currently-live partition, or
its control-session identity cannot be verified, the assignment fails closed.
Bring the intended agent online and resolve the identity condition before trying
again. A displayed partition is informational; it is checked again on save so a
reconnect between viewing the form and confirming it cannot redirect the work.

Older deployments may contain a disabled assignment marked **Unbound legacy
assignment -- reapproval required**. This is expected after the partition-binding
migration: ServiceRadar intentionally did not infer an old assignment's partition
from current inventory metadata.

The Plugins index has a **Legacy recovery candidates** table scoped to the current
workspace. It shows the affected agent, plugin package, recovery kind, safe
status, and a **Review** link. The queue is bounded to 50 cursor-backed rows per
page and shows only rows that still need action; a successfully reapproved or
reconciled historical row leaves the queue and retains only its safe completion
state in package detail. Treat it as a review queue, not a bulk repair tool: it
deliberately has no bulk enable action, deep offset scan, or `default`
partition assumption.

1. Use **Review**, confirm the target agent is connected, and verify the package
   is still approved.
2. For a manually owned assignment, use **Reapprove** and explicitly confirm the
   replacement. ServiceRadar creates a new, partition-bound assignment and leaves
   the historical row disabled for audit.
3. For a policy- or credential-rule-owned assignment, use **Reconcile policy**.
   Do not manually clone its old configuration. Reconciliation re-evaluates the
   currently enabled owner, target scope, package, schema, and live agent
   identity before it can materialize a new assignment. The status refreshes while
   it is queued or running and then shows a safe terminal outcome; refresh the
   package detail if the browser session ends before it completes.
4. Wait for the agent's next plugin result, then verify the restored service in
   `/services` and the assignment detail view.

Manual recovery requires plugin-assignment permission. Policy recovery requires
current authority for its owning source; credential-rule recovery also requires
credential-management permission. If that credential permission is absent, the
reconciliation action is disabled and rejects a direct browser submission with
the same missing-permission explanation. The control plane rechecks all
authority before executing, so browser state never grants access by itself. The
recovery UI shows only a safe state: `Reapproved` for a completed manual row, or
a normalized policy state and replacement count for a policy row. Raw recovery
audits and durable recovery requests remain internal; the UI does not show
request parameters, principals, owner metadata, replacement IDs, secret values,
tokens, or private material. Do not re-enable unbound rows with direct database
updates.
Do not alter or delete them through raw database access; use the audited recovery
actions so the historical row remains available for investigation.

### First-party plugin import

ServiceRadar ships first-party Wasm plugins as signed artifacts published by release automation. The Plugins UI can sync a first-party plugin index, verify the referenced signed bundle, mirror the Wasm payload into ServiceRadar-managed plugin storage, and stage the package for normal capability review. Imported first-party packages are not assignable until an authorized operator approves them.

### GitHub imports and verification

For GitHub-sourced plugins, the control plane fetches `plugin.yaml`, `plugin.wasm`, and an optional config schema. Commit verification is captured from GitHub. If `PLUGIN_REQUIRE_GPG_FOR_GITHUB=true`, unsigned or unverified commits are rejected during import.

## Deployment and Storage Configuration

Wasm packages are served by the web-ng API and stored using a configurable backend. For production, store plugin blobs on persistent storage and back them up with normal platform operations. Plugin blob authorization is token-gated, with bearer tokens carried in request headers or POST bodies rather than embedded in request URLs.

### Filesystem backend (default)

- Storage path: `/var/lib/serviceradar/plugin-packages`
- Configure web-ng with:
  - `PLUGIN_STORAGE_BACKEND=filesystem`
  - `PLUGIN_STORAGE_PATH=/var/lib/serviceradar/plugin-packages`
  - `PLUGIN_STORAGE_SIGNING_SECRET` (shared with core for signed plugin blob tokens)
- Docker: mount a volume to `/var/lib/serviceradar/plugin-packages` in the `web-ng` container.
- Kubernetes: mount a PVC at `/var/lib/serviceradar/plugin-packages` for the `web-ng` deployment.

For core plugin blob delivery, set:

- `PLUGIN_STORAGE_PUBLIC_URL` — base URL for web-ng (your deployment's web-ng endpoint)
- `PLUGIN_STORAGE_SIGNING_SECRET` — must match web-ng
- `PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS` — default `86400`

Agents receive a plain plugin blob endpoint plus a separate short-lived token, so plugin config never contains a tokenized URL.

### JetStream object store

To store plugin blobs in NATS JetStream instead, set:

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

### AlienVault OTX Threat Intel

ServiceRadar ships a first-party `alienvault-otx-threat-intel` Wasm plugin for edge-side OTX collection. Use **Settings -> Networks -> Threat Intel** to assign the approved package to an agent, set the OTX base URL, page size, timeout, and a secret reference for the API key. The key is used by the plugin through the normal secret-ref flow and is not displayed back in the UI. The edge plugin needs outbound HTTPS egress to the configured OTX host, normally `otx.alienvault.com:443`.

The collector emits each accepted OTX page immediately as a separate plugin-result chunk. Submission waits for admission to the agent's bounded result queue before the plugin advances, while the gateway can forward admitted chunks as the Wasm invocation fetches later pages. The collector therefore does not assemble the full subscribed corpus in memory or silently drop a page under queue pressure. Core upserts each accepted page in transactional batches and advances the edge cursor only after persistence succeeds; a failed batch leaves the contiguous cursor safe for an idempotent retry.

Page size, pages per invocation, request timeout, retry attempts, the pull-wide attempt and wall-time budgets, and the host payload admission limit remain enforced. If a run reaches one of those bounds, core persists the continuation page and effective page size; the next scheduled invocation resumes there. Core-worker collection also queues the provider continuation instead of restarting at page one, then stores a completion high-water with a two-day overlap for the next root sync. Retrospective NetFlow matching walks the imported corpus with an internal UUID keyset batch and stores progress on the retrohunt run.

There is no separate `Max IOCs` completeness cap. Legacy `max_iocs`, `max_indicators`, and `otx_max_indicators` values are accepted and ignored. Assignment edits preserve unrelated configuration while removing the obsolete keys. The legacy database column remains inert for rollback compatibility during this release window and can be removed by a later cleanup migration after older supported releases no longer read it.

Core-hosted OTX sync is also available for deployments that prefer the control plane to poll OTX directly. Configure the core worker with these environment variables:

- `SERVICERADAR_OTX_API_KEY` or `SERVICERADAR_OTX_API_KEY_FILE`
- `SERVICERADAR_OTX_BASE_URL` (defaults to `https://otx.alienvault.com`)
- `SERVICERADAR_OTX_PAGE_SIZE`
- `SERVICERADAR_OTX_TIMEOUT_MS`
- `SERVICERADAR_OTX_MAX_RETRIES`
- `SERVICERADAR_OTX_BACKOFF_MS`
- `SERVICERADAR_OTX_MODIFIED_SINCE`
- `SERVICERADAR_OTX_PARTITION`

Prefer the `*_FILE` form for Kubernetes secrets. Rotate OTX keys through the secret backend or Kubernetes secret, then restart or roll the affected pod so runtime config is refreshed. After rotation, use **Sync Now** on the Threat Intel settings page and verify Sync Health shows a fresh successful run.

When raw payload archival is enabled in Threat Intel settings, core stores decoded OTX page payload snapshots in NATS Object Store. Archival is optional; if NATS Object Store is unavailable, normalized indicator ingest continues and the archive failure is logged. The core defaults are:

- `SERVICERADAR_OTX_RAW_BUCKET=serviceradar_threat_intel`
- `SERVICERADAR_OTX_RAW_TTL_SECONDS=0`
- `SERVICERADAR_OTX_RAW_MAX_BUCKET_BYTES`
- `SERVICERADAR_OTX_RAW_MAX_CHUNK_BYTES`
- `SERVICERADAR_OTX_RAW_REPLICAS=1`
- `SERVICERADAR_OTX_RAW_STORAGE=file`

## Operational Tips

- Keep per-agent engine limits conservative and override down in assignments if needed.
- Use the **Settings -> Agent capacity** view to confirm headroom before assignments.
- Store plugin source details in the manifest `source` section for auditability.
- Review `signal_schemas` for plugins that emit events or logs; missing contracts
  force the UI back to generic JSON rendering.
- Plugin result payloads should use canonical statuses `OK`, `WARNING`, `CRITICAL`, or `UNKNOWN`. The agent maps common failure aliases (`failed`, `fail`, `error`) to `CRITICAL` so a failed execution is visible as unhealthy.
