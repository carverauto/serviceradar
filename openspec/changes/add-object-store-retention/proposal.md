# Change: Add Object Store Retention and Inventory

## Why
ServiceRadar now stores durable artifacts in NATS JetStream Object Store, including mirrored agent release payloads and uploaded Wasm plugin packages, but there is no coordinated cleanup routine. That creates unbounded storage growth and makes production disk pressure harder to reason about.

The current datasvc object API also supports delete-by-key, but not object inventory. Without a list/metadata API, cleanup can only remove keys already referenced in the database and cannot identify orphaned objects left behind by failed publishes, failed uploads, or deleted database records.

## What Changes
- Inventory every ServiceRadar-owned Object Store namespace currently written by the application:
  - datasvc-backed agent release artifacts under `agent-releases/<version>/...`
  - web-ng plugin package blobs under `plugins/<plugin_id>/<version>/<package_id>.wasm`
- Add a datasvc object inventory API that lists object metadata by domain/prefix with bounded pagination and RBAC.
- Add reference-aware retention workers for agent release artifacts and plugin package blobs.
- Keep the latest configurable number of mirrored agent releases by default, with a default of 5 retained releases.
- Protect objects referenced by active rollouts, rollout targets, approved/staged plugin packages, plugin assignments, or policy assignments.
- Add dry-run/summary logging so operators can see what would be removed before enabling destructive cleanup.
- Expose cleanup through Oban-backed scheduling and manual job execution.

## Impact
- Affected specs:
  - `data-service-storage`
  - `edge-architecture`
  - `wasm-plugin-system`
  - `job-scheduling`
- Affected code:
  - `proto/data_service.proto`
  - `go/pkg/datasvc/*`
  - `elixir/serviceradar_core/lib/serviceradar/sync/client.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/*`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/*`
  - Oban job catalog/configuration and tests
