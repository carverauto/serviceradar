# Change: Add Endpoint SBOM Inventory

## Why
Operators need first-party endpoint software visibility to answer incident questions such as "which assets have nginx installed?" without relying on demo fixtures, ad hoc SSH checks, or external endpoint tools. ServiceRadar currently has bounded Bumblebee exposure findings and process/flow attribution, but it does not collect full installed package inventory or endpoint SBOM artifacts.

## What Changes
- Add an opt-in endpoint software inventory collector for managed agents.
- Generate and ingest CycloneDX JSON SBOM artifacts for installed operating-system packages and selected application package manifests.
- Store raw SBOM artifacts in durable object storage with hashes, size limits, retention metadata, and upload provenance.
- Normalize package/component rows into CNPG so assets can be queried by package name, version, ecosystem, CPE, PURL, and source manager.
- Surface current inventory state on devices/assets and provide an API/SRQL-ready data model for later CTI and CVE matching work.
- Keep endpoint collection disabled by default, policy controlled, bounded, and privacy-redacted.

## Impact
- Affected specs: endpoint-software-inventory, agent-configuration, data-service-storage, device-inventory
- Affected code:
  - `go/pkg/agent/**`
  - `go/cmd/agent/**`
  - `build/native_addons/**`
  - `proto/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/serviceradar_core/lib/**`
  - `elixir/web-ng/lib/**`
  - `rust/srql/**`
  - `helm/serviceradar/**`

## Non-Goals
- Do not enable full package or filesystem inventory by default.
- Do not perform broad filesystem hashing in the first implementation.
- Do not implement the full CTI observable matcher from `add-cti-signal-coverage` in this slice.
- Do not replace Bumblebee exposure scanning; endpoint SBOM inventory complements it with durable package/component state.

## Dependencies
- Agent configuration delivery must be able to assign an endpoint inventory profile to a managed agent.
- Datasvc object uploads must keep enforcing bounded object size and storage limits for raw SBOM artifacts.
- Database schema changes must be implemented through Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/`.
