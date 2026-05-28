## Context
Bumblebee is an upstream Go scanner for macOS and Linux developer endpoints. It reads local package, extension, browser, and developer-tool metadata and emits NDJSON records. When given an exposure catalog, it can emit finding records for exact catalog matches without requiring full inventory upload.

ServiceRadar should use Bumblebee as an opt-in agent capability, not as an always-on inventory collector. The initial implementation should bias toward incident response and low data exposure: findings and scan summaries are ingested by default, while full package records remain disabled unless an operator explicitly opts in later.

## Goals
- Run bounded, read-only Bumblebee scans from a root-owned scheduled scanner service while keeping `serviceradar-agent` non-root.
- Keep scan enablement, roots, profiles, ecosystems, and cadence under existing agent configuration control.
- Maintain a reviewed exposure catalog snapshot in the control plane and deliver a stable snapshot to agents.
- Normalize findings into the existing observability/risk pipeline with source provenance.
- Link Bumblebee posture to the canonical device record created for the reporting agent.
- Preserve last-known-good catalog and agent scan behavior when external catalog fetches fail.

## Non-Goals
- Replacing SBOM, vulnerability management, or EDR workflows.
- Executing package managers, source-code inspection, or remediation commands from ServiceRadar.
- Uploading full developer workstation inventory by default.
- Adding multitenancy, customer-specific routing, or public schema database objects.

## Decisions
- Treat Bumblebee as a one-shot scanner invoked by a root-owned scheduled scanner service under a bounded timeout. This matches the upstream execution model, gives the scanner enough filesystem access for all-user coverage, and avoids running the main agent as root.
- Vendor the pinned upstream Bumblebee scanner implementation and call it in-process from `serviceradar-bumblebee-scan`. Do not ship a second upstream Bumblebee CLI binary or shell out to another scanner executable at runtime.
- Keep the base `serviceradar-agent` package free of Bumblebee root components. The root helper, scanner config, systemd unit/timer, state directory permissions, and add-on manifest belong in an explicit Edge Ops native capability bundle so operators choose whether privileged scanning is installed.
- On Linux, the optional native capability bundle packages the scanner as a systemd unit/timer pair such as `serviceradar-bumblebee-scan.service` and `serviceradar-bumblebee-scan.timer`. The timer provides the normal cadence; future on-demand runs should prefer systemd activation rather than a custom privileged RPC protocol.
- The root-owned scanner service writes sanitized findings, scan summaries, and coverage metadata to a bounded spool path under `/var/lib/serviceradar/bumblebee/`. The non-root agent reads only that spool output and never reads arbitrary user home directories directly.
- Do not rely on Bumblebee's default `~` expansion for fleet coverage. The scanner service will resolve scan roots before invocation, supporting current-user roots, all local user home directories, `/root`, and explicit operator-supplied roots according to a bounded allow/deny policy.
- Store catalog snapshots in CNPG under the `platform` schema via Elixir migrations. The Go ingestion path must not create schema or run DDL.
- Use AshPaperTrail for operator-managed Bumblebee resources: scan profiles/configuration, catalog source configuration, catalog snapshot promotion state, and composite risk policy/contribution records where changes are control-plane decisions. Follow the existing `AshPaperTrail.Resource` + project-owned mixin pattern used by security, credentials, automation, and inventory resources.
- Do not use AshPaperTrail for high-volume raw scan finding churn. Findings and scan summaries need their own bounded current-state/history tables with explicit retention, because versioning every ingest update would create noisy audit history and unnecessary storage pressure.
- Store current Bumblebee posture and finding state in platform-scoped tables keyed by canonical `device_uid` and `agent_id`. The agent ID is the ingestion identity; the device UID is resolved from the agent registry/device mapping so device details can show posture on the same record operators already inspect.
- Feed Bumblebee posture into the device composite risk model as a source-specific contribution. Source ingestors update only their own contribution rows; they do not write the final inventory risk score directly.
- Treat the inventory-visible `risk_score`/`risk_level` as derived composite risk. The reducer computes the final score from active source contributions, so an Armis update can lower the Armis contribution without clobbering a higher active Bumblebee contribution.
- Preserve the Bumblebee contribution, contributing finding counts, and catalog snapshot separately from the final composite score so operators can explain why a device risk changed.
- If an agent report arrives before the canonical device mapping is available, store it as agent-scoped pending posture and backfill `device_uid` when the agent/device association is established.
- Refresh the catalog through an AshOban-backed Ash action owned by core. The job writes a candidate snapshot, validates schema/version consistency, materializes an immutable catalog artifact, and promotes it only after successful parse.
- Version every catalog snapshot as a first-class identity. Track source ID, upstream revision, normalized catalog version, content SHA256, object-store key, promoted timestamp, and validation metadata. Agents and findings refer to this immutable snapshot reference, not to a mutable "latest" label.
- Stage promoted catalog artifacts in datasvc-backed NATS Object Storage. The control plane sends agents a catalog assignment through the existing agent config/control path; the assignment includes snapshot ID, object key, content hash, size, and promoted revision.
- Use `AgentCommandBus`/agent-gateway for nudging online agents to fetch or activate a promoted catalog snapshot. The gateway brokers delivery/access to the object-store artifact; agents cache the verified snapshot locally and fall back to last-known-good when the control plane is unreachable.
- Do not push raw upstream catalog URLs to agents for normal operation. Agents should not fetch upstream Bumblebee catalog sources directly, because that bypasses control-plane review, pinning, and auditability.
- Ingest finding records and scan summaries by default. Package inventory records are dropped unless a later approved change enables inventory retention.
- In the UI, surface Bumblebee in device details as a security/supply-chain posture panel: status, source-specific risk contribution, composite risk impact, finding counts by severity, catalog snapshot, last successful scan, coverage completeness, and a bounded findings table. Do not present an unscanned or partial-coverage device as clean.

## Risks And Mitigations
- **Sensitive local paths**: Bumblebee records may include project/source paths. Store bounded path metadata, redact home-directory prefixes where possible, and document exposure.
- **Privilege boundary**: The main agent must not become root to scan other user homes. Keep privilege in a dedicated scanner service with fixed configuration files, bounded arguments, environment scrubbing, read-only scanner behavior, and sanitized spool output.
- **Partial user coverage**: The system must distinguish no findings from incomplete coverage. The scanner service reports attempted roots, scanned roots, skipped roots, and skip reasons, including whether `/root` was covered.
- **Device association gaps**: Some early agent reports may arrive before device identity reconciliation has attached a canonical device. Persist those reports by `agent_id` and backfill `device_uid`; the UI should show the panel only after association or from an agent-specific view.
- **Risk clobbering**: Existing source ingestors may treat `ocsf_devices.risk_score` as a direct source field. Move risk writes behind a reducer boundary so source updates affect their source-specific contribution only, and the device inventory score remains the max or policy-selected composite output from all active sources.
- **Audit noise**: Bumblebee can update findings on every scan. Keep AshPaperTrail focused on configuration, catalog promotion, and risk policy/resource state; use dedicated finding history/observability events for scan output.
- **Catalog drift**: Pin the upstream repository revision used for seeded catalogs, promote immutable snapshot versions, mirror promoted artifacts to object storage, and track promoted snapshot IDs plus content hashes in findings.
- **Scanner failure noise**: Report scan errors as health/status records with bounded error reasons; do not create exposure findings from failed scans.
- **Unbounded scans**: Enforce max duration, root count, root allow/deny behavior, and output size limits in the agent before accepting configuration.

## Open Questions
- Should catalog refresh read directly from upstream GitHub, an internal mirror, or a release-pinned artifact for production deployments?
- Should macOS ship a launchd job in the first implementation or remain Linux-only until the Linux service path is validated?
- What is the initial Bumblebee contribution formula for multiple findings on one device: max severity, weighted sum, or capped additive score?
- Should the first composite reducer use max-active-source semantics or a weighted policy? Max-active-source is the safest initial behavior for avoiding lower-confidence sources reducing higher active risk.
- Should the first UI surface live in the default device details summary or a dedicated Security tab if the device details page already has many panels?
