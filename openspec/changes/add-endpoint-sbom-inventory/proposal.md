# Change: Add Endpoint SBOM Inventory

## Why
Operators need first-party endpoint software visibility to answer incident questions such as "which assets have nginx installed?" without relying on demo fixtures, ad hoc SSH checks, or external endpoint tools. ServiceRadar currently has bounded Bumblebee exposure findings and process/flow attribution, but it does not collect full installed package inventory or endpoint SBOM artifacts.

The initial design must also scale beyond small fleets. Uploading a full package/SBOM snapshot from every endpoint on every scan would turn routine inventory collection into high-volume database churn. Endpoint software inventory should keep detailed state close to the endpoint, persist central state only when it changes, and support live fleet questions through the existing gateway command path.

## What Changes
- Add an opt-in endpoint software inventory collector for managed agents.
- Generate CycloneDX JSON SBOM artifacts for installed operating-system packages and selected application package manifests, but upload full artifacts only when the endpoint inventory content hash changes or an operator explicitly requests a refresh.
- Maintain a local last-known-good inventory cache on the endpoint with deterministic package-set and artifact hashes.
- Store raw SBOM artifacts in durable object storage with content-addressed hashes, size limits, retention metadata, upload provenance, and dedupe semantics.
- Normalize package/component rows into CNPG for current changed inventories so assets can be queried by package name, version, ecosystem, CPE, PURL, and source manager without rewriting unchanged rows on every scan.
- Add a bounded on-demand query path over the existing agent-gateway command bus so operators can ask connected agents or cohorts live package/SBOM questions and receive compact answers without forcing full database ingest.
- Surface current inventory state on devices/assets and provide SRQL/API support for both latest persisted state and live query results.
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
- Do not attempt to implement a peer-to-peer endpoint chain. ServiceRadar will use its existing agent-gateway partitioning and control stream for on-demand commands.
- Do not make Postgres the first stop for every unchanged package scan.

## Dependencies
- Agent configuration delivery must be able to assign an endpoint inventory profile to a managed agent.
- Datasvc object uploads must keep enforcing bounded object size and storage limits for raw SBOM artifacts.
- The existing agent-gateway control stream and command bus must route on-demand inventory queries to connected agents without inbound connectivity to endpoints.
- Database schema changes must be implemented through Elixir migrations under `elixir/serviceradar_core/priv/repo/migrations/`.
