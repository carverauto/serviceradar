## Context
The platform has several adjacent signals but no durable endpoint package inventory:
- Bumblebee reports bounded exposure findings and scan metadata, not full installed package inventory.
- Sysmon reports host/process metrics, not package manager or SBOM state.
- Flow attribution records process context for network activity, not installed software inventory.
- Release/build SBOM documentation covers ServiceRadar artifacts, not customer endpoints.

This proposal creates a focused first slice of the broader endpoint inventory work described in `add-cti-signal-coverage`.

## Goals
- Collect installed software inventory from agents in a way that is explicit, bounded, and operationally explainable.
- Preserve a raw CycloneDX JSON artifact for auditability and later reprocessing.
- Normalize common package fields for fast asset/package lookups.
- Keep privacy-sensitive paths and file metadata opt-in.
- Make the collector safe to roll out gradually by profile, tag, or direct agent assignment.

## Non-Goals
- Vulnerability feed ingestion, CVE scoring, and CTI matcher implementation.
- Unbounded file crawling or whole-disk hash inventories.
- Mandatory deployment in the base agent profile.

## Collector Model
Endpoint inventory should run as a signed native add-on or tightly scoped agent subcommand rather than expanding the always-on agent hot path. The collector writes a sanitized spool artifact to the local ServiceRadar state directory. The agent reads only the latest valid artifact, validates size and schema, attaches agent identity/provenance, and uploads it through the control plane.

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
- Object key and storage bucket.
- Redaction policy and enabled collection sources.

## Storage Model
The raw SBOM artifact is stored in durable object storage through datasvc. Normalized rows are stored in the `platform` schema through Elixir migrations:
- Inventory scan runs.
- SBOM artifact metadata.
- Package/component rows with package manager, ecosystem, name, version, architecture, PURL, CPE values, supplier, license when available, and source evidence.

The current inventory view is derived from the latest successful scan per agent/device. Historical scans are retained according to policy so operators can answer "when did this package appear or disappear?" without keeping artifacts forever.

## Privacy And Safety
Collection is disabled by default. Profiles must opt in to sources such as OS packages, language manifests, listening services, and executable metadata separately. File paths and command-line-derived values are redacted unless a policy explicitly enables them.

Agents reject artifacts that exceed configured bounds, fail schema validation, or come from an unexpected collector version/signature. The previous successful inventory remains current if a scan fails.

## Open Questions
- Whether the first implementation should upload directly through datasvc or through an agent-gateway relay RPC that delegates artifact storage.
- Whether package diffing should be computed during ingestion or materialized asynchronously.
- Which UI surface ships first: device detail package tab, SRQL-only queryability, or both.
