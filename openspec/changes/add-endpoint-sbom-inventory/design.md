## Context
The platform has several adjacent signals but no durable endpoint package inventory:
- Bumblebee reports bounded exposure findings and scan metadata, not full installed package inventory.
- Sysmon reports host/process metrics, not package manager or SBOM state.
- Flow attribution records process context for network activity, not installed software inventory.
- Release/build SBOM documentation covers ServiceRadar artifacts, not customer endpoints.

This proposal creates a focused first slice of the broader endpoint inventory work described in `add-cti-signal-coverage`.

## Goals
- Collect installed software inventory from agents in a way that is explicit, bounded, and operationally explainable.
- Preserve a raw CycloneDX JSON artifact for auditability and later reprocessing when the inventory changes or an operator forces a refresh.
- Normalize common package fields for fast asset/package lookups while avoiding central rewrites for unchanged inventories.
- Keep detailed collection, package matching, and point-in-time questions close to the endpoint whenever a live query can answer the operator's question more cheaply than database ingest.
- Support cohort and fleet queries through gateway-routed on-demand commands that return compact answers.
- Keep privacy-sensitive paths and file metadata opt-in.
- Make the collector safe to roll out gradually by profile, tag, or direct agent assignment.

## Non-Goals
- Vulnerability feed ingestion, CVE scoring, and CTI matcher implementation.
- Unbounded file crawling or whole-disk hash inventories.
- Mandatory deployment in the base agent profile.
- Peer-to-peer endpoint chaining or endpoint-to-endpoint transport.
- Treating historical full-package snapshots as the default data plane.

## Architecture Decision
Endpoint inventory will be a hybrid of persisted current state and live endpoint query:
- The endpoint collector builds a normalized package manifest locally.
- The agent computes deterministic hashes for the normalized package set and the raw CycloneDX artifact.
- The agent reports scan metadata, counts, source summaries, and hashes on each scheduled scan.
- The agent uploads the raw artifact and normalized package rows only when the package-set or artifact hash changes, or when policy/operator action forces a refresh.
- The control plane stores current changed inventory in CNPG for common SRQL/device-detail queries and bounded historical explanation.
- The on-demand query path asks connected agents or cohorts to evaluate package predicates against their local cache and returns compact matches through agent-gateway.

This gives operators durable latest-known inventory without turning every scan on every endpoint into a full central write. It also provides a path for large fleet incident questions such as "who has nginx 1.24?" to run against endpoint-local state first, with central persistence used for audit, offline assets, and trend/history.

## Collector Model
Endpoint inventory should run as a signed native add-on or tightly scoped agent subcommand rather than expanding the always-on agent hot path. The collector writes a sanitized spool artifact and normalized manifest to the local ServiceRadar state directory. The agent reads only the latest valid output, validates size and schema, attaches agent identity/provenance, and updates a local last-known-good cache.

The local cache stores:
- Latest normalized package manifest.
- Deterministic package-set hash computed from sorted normalized package identity fields.
- Raw artifact hash and optional local artifact path.
- Source summaries and package counts.
- Scan status, timestamps, collector version, and redaction policy.
- Last successfully uploaded package-set hash and artifact hash.

If a scan succeeds but the package-set hash has not changed, the agent reports a lightweight unchanged scan status and skips full artifact/package upload. If a scan fails, the previous successful cache remains eligible for on-demand queries and remains the current persisted state.

The first Linux implementation should cover:
- OS release and kernel metadata.
- dpkg/apt, rpm/dnf/yum, and apk package databases where present.
- Optional language manifest discovery for bounded paths configured by policy.
- Optional listening-service and executable metadata only when enabled by policy.

## SBOM Format
CycloneDX JSON is the first supported endpoint SBOM format because it has a compact component model, Package URL support, and broad parser/tooling support. SPDX can be considered later through a format adapter if an operator needs it.

Each uploaded artifact records:
- Format and spec version.
- Agent ID, canonical device ID when resolved, scan ID, collector version, and scan timestamps.
- SHA-256 digest and byte size.
- Package-set hash derived from normalized component identity fields.
- Object key and storage bucket.
- Redaction policy and enabled collection sources.

## Storage Model
The raw SBOM artifact is stored in durable object storage through datasvc only when content changes or an operator forces upload. Objects should be addressed by hash or carry a content-hash identity so repeated identical SBOMs do not create duplicate object-store pressure.

Normalized rows are stored in the `platform` schema through Elixir migrations:
- Inventory scan runs.
- SBOM artifact metadata.
- Package/component rows with package manager, ecosystem, name, version, architecture, PURL, CPE values, supplier, license when available, and source evidence.
- Package-set hash, artifact hash, unchanged-scan markers, and upload reason.

The current inventory view is derived from the latest successful changed scan per agent/device. A successful unchanged scan updates freshness metadata and source summaries without deleting/reinserting package rows. Historical changed scans are retained according to policy so operators can answer "when did this package appear or disappear?" without keeping every unchanged scan or artifact forever.

## On-Demand Query Model
The existing agent-gateway command bus is the transport for live inventory questions. The control plane creates an endpoint inventory query command with:
- Query ID, TTL, requester identity, and target scope.
- A bounded predicate set such as package name, version constraint, package manager, ecosystem, PURL, CPE, source, or package-set hash.
- Result limits and redaction options.
- A flag indicating whether stale local cache is acceptable or a fresh scan is required.

Gateways dispatch commands only to connected agents that advertise the endpoint inventory capability. Agents evaluate predicates against the local last-known-good manifest. Results are compact by default: agent ID, device UID when known, match count, matched package identities, package-set hash, scan timestamp, and freshness. Operators can separately request full artifact upload or a fresh scan for selected agents.

This path intentionally favors "answer the question" over "upload the database." It should be used for broad fleet questions, while SRQL over CNPG remains the path for latest persisted state, offline assets, dashboards, and historical reporting.

## Privacy And Safety
Collection is disabled by default. Profiles must opt in to sources such as OS packages, language manifests, listening services, and executable metadata separately. File paths and command-line-derived values are redacted unless a policy explicitly enables them.

Agents reject artifacts that exceed configured bounds, fail schema validation, or come from an unexpected collector version/signature. The previous successful inventory remains current if a scan fails.

On-demand queries must enforce the same source and redaction policy as scheduled collection. A command cannot cause collection of a disabled source unless the assigned endpoint inventory policy allows that source and the command requester is authorized to force a scan.

## Scale And Retention
The expected large-fleet behavior is:
- Routine scans send lightweight status/hash summaries.
- Full artifact uploads occur only on first scan, changed package set, changed artifact, or explicit force.
- Unchanged scan metadata is compacted aggressively.
- Current package rows are replaced only for changed inventories.
- Historical package rows and artifacts have independent retention windows.
- Fleet-wide live queries use compact agent responses and per-command TTL/result limits.

This model keeps central storage useful for audit and offline/latest-known answers while preventing scan cadence multiplied by endpoint count from becoming the primary database write load.

## Open Questions
- Whether artifact upload should be initiated directly through datasvc or always through an agent-gateway relay RPC that delegates artifact storage.
- Whether package diffs should be computed on the agent from local previous state, during ingestion, or materialized asynchronously.
- Whether the first live query UI should be a device-scoped "refresh/check package" action, a fleet query form, or both.
- What stale-cache threshold should make live query results display as stale rather than current.
