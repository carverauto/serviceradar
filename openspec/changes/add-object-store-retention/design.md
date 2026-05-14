## Context
The current Object Store write paths are:

- Agent releases: `ServiceRadar.Edge.ReleaseArtifactMirror` mirrors signed release artifacts through datasvc using object keys shaped as `agent-releases/<version>/<sha256>-<platform>-<filename>`.
- Plugin packages: `ServiceRadarWebNG.Plugins.Storage` writes uploaded package blobs either to filesystem storage or directly to a JetStream Object Store bucket using keys shaped as `plugins/<plugin_id>/<version>/<package_id>.wasm`.

Existing deletion support is partial:

- Datasvc has `DeleteObject` and `GetObjectInfo`, but no list/inventory RPC.
- Plugin storage has `delete_blob/1`, and the admin UI attempts to delete the blob when a package is deleted.
- Plugin JetStream bucket TTL can be configured, but TTL is not reference-aware and can delete active packages.

## Goals / Non-Goals
- Goals:
  - provide an operator-visible inventory of ServiceRadar-owned object namespaces
  - bound Object Store growth with scheduled cleanup
  - preserve artifacts that active agents, rollouts, or plugin assignments may need
  - make destructive cleanup idempotent and safe to retry
- Non-Goals:
  - replace JetStream Object Store with S3/MinIO
  - redesign release publishing or plugin package approval workflows
  - rely on blind bucket TTL for active artifact retention

## Decisions
### Datasvc gets a list metadata API
Datasvc should expose a read-only `ListObjects` style RPC that returns object metadata without payload bytes. The request should include optional domain/prefix filters and pagination controls. The response should cap page size server-side so a caller cannot load an entire bucket into memory.

This is needed for agent release cleanup because the mirrored release bucket is hidden behind datasvc. Delete-by-known-key is not enough to find orphaned objects.

### Cleanup is reference-aware
Retention must be based on both object age/version and live references:

- Agent releases are protected when they are among the newest retained releases, referenced by active or non-terminal rollout/target records, or still needed for rollback/current desired agent versions.
- Plugin packages are protected when their database record is staged or approved, when any assignment/policy references the package, or while upload/review workflows are still active.

### Plugin cleanup uses the plugin storage abstraction
Plugin package blobs are currently stored by web-ng rather than datasvc. The implementation should extend `ServiceRadarWebNG.Plugins.Storage` with inventory support for filesystem and JetStream backends, then run plugin retention through that abstraction instead of directly reaching into JetStream from unrelated modules.

### Scheduled cleanup runs through Oban
This is fixed system maintenance rather than a per-resource schedule, so the implementation should use an Oban maintenance worker with uniqueness and safe insertion. If the job catalog supports manual execution for maintenance workers, object retention should be listed there so operators can run it on demand.

### Dry-run is first-class
The cleanup routine should support dry-run mode and log/return:

- namespace or bucket
- objects scanned
- objects protected
- objects eligible
- objects deleted
- total bytes eligible/deleted when metadata exposes size
- failures by key

Dry-run is important because production Object Store contents may include historical data from earlier builds.

## Risks / Trade-offs
- A too-aggressive retention policy could break rollouts or plugin execution.
  - Mitigation: protect all live references and default to dry-run for new destructive flows where practical.
- Inventory listing may expose sensitive object names to callers.
  - Mitigation: use existing datasvc mTLS/RBAC and grant list access only to roles that can already read object metadata.
- Listing large buckets may be expensive.
  - Mitigation: require prefix filters for cleanup jobs, cap page size, and process pages incrementally.
- Existing orphaned plugin blobs may not be discoverable through database rows.
  - Mitigation: add backend-level inventory for plugin storage before attempting orphan cleanup.

## Migration Plan
1. Add datasvc object metadata listing to protobuf, Go server/store, RBAC, and Elixir sync client.
2. Add inventory helpers for plugin storage backends.
3. Implement dry-run retention planners for agent release artifacts and plugin package blobs.
4. Add destructive delete mode after planner tests prove protected references are retained.
5. Add Oban worker scheduling/manual execution and operator-visible logs.
6. Document object namespaces, retention defaults, and operational cleanup commands.

## Open Questions
- Should object retention be disabled by default initially with dry-run enabled, or enabled immediately with conservative defaults?
- Should plugin package blobs eventually move behind datasvc for one object-store API surface, or should web-ng keep owning direct plugin storage?
- Do we want retention settings in Helm values only, or also in the admin job/settings UI?
