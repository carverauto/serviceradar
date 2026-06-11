# Change: Fix endpoint inventory profile operations

## Why
Endpoint inventory is not operationally explainable today. Agents that should have a full OS package inventory show only two packages or none, add-on profile reconciliation can crash from invalid Ash action context access, and the UI makes operators choose between SRQL profiles and manual assignments without showing which path actually owns the deployed configuration.

The endpoint software data also lands in the device details experience without a clear home. Operators need a dedicated Software tab with scan coverage and package source diagnostics so "2 packages installed" is immediately recognizable as complete, partial, stale, or failed.

## What Changes
- Treat SRQL add-on profiles as the primary endpoint inventory assignment path, with `in:devices` as the simple default and manual assignments clearly marked as advanced overrides.
- Fix add-on profile action execution so preview and reconcile actions use Ash context correctly, return bounded errors, and never crash the LiveView process.
- Add a profile eligibility and diagnostics contract that shows matched devices, resolved agents, eligible targets, skipped targets, and package/config delivery state.
- Add endpoint inventory source diagnostics from collector through ingest and UI: detected package managers, per-source package counts, skipped/error reasons, payload bounds, scan freshness, and partial-state indicators.
- Move endpoint software package inventory to a dedicated Software tab on device details.
- Simplify the endpoint inventory setup UI by hiding low-level paths, raw JSON, and rarely-used collector knobs behind an advanced section.
- Add a generic vulnerability intelligence source registry and advisory batch contract for endpoint inventory matching. Feed-specific download, schema validation, archive handling, and normalization live in add-ons or Wasm plugins, not in core. Durable feed artifact staging is brokered through agent-gateway/SDK APIs; producers never access JetStream object storage directly.
- Add a scanner-agnostic add-on contract for endpoint inventory, SBOM generation, scan activity, and finding emission. Core/agent/gateway pipelines SHALL depend on generic contracts and OCSF-derived schemas, not on a specific scanner implementation.
- Use an OSV ScaLibr-backed scanner package as the first implementation of that scanner contract. ScaLibr-specific code, naming, configuration, and diagnostics SHALL stay inside the producer package/contract; it SHALL NOT be embedded into core or bypass agent-gateway/data-service boundaries.
- Treat native add-ons and Wasm plugins as first-class vulnerability intelligence producer runtimes. Large feed handling, pointer JSON, zips, checksum validation, credentials, and durable artifact staging SHALL use SDK/ABI calls backed by agent-gateway, not direct object-store access. Wasm plugins are valid for these producers when the host ABI exposes the required gateway-brokered capabilities; native packaging is only required when the producer needs OS/runtime capabilities outside the Wasm sandbox.
- Add a generic producer schedule contract for feed-producing plugins/add-ons. Producer packages declare schedulable actions, cadence bounds, required settings, credential refs, and command payload shape in their package manifest/SDK contract; the platform absorbs that contract on install, renders settings UI from it, stores operator cadence choices, and uses AshOban plus the agent commandbus to dispatch due runs.
- Keep Trivy as the Kubernetes/container report ingestion path while preserving the same generic OCSF scan/finding model for scanner outputs. Central vulnerability matching consumes normalized advisory batches submitted by intelligence producers.
- Match endpoint package/SBOM coordinates against vulnerability feeds in the control plane, not on agents, and surface matched vulnerability/KEV findings in the Software tab.
- Improve Trivy and Falco result extraction so their reports become device/resource-linked OCSF scan activity and findings with useful evidence fields, dedupe keys, and queryable vulnerability/detection details instead of mostly raw payload storage.
- Make `/security` actionable for Trivy and Falco: aggregate report rows must drill into individual findings/detections with affected resource, package/process/container evidence, remediation fields, and raw event links only as secondary audit context.
- Add tests and demo validation requirements for profile reconciliation, endpoint inventory diagnostics, and the Software tab.

## Impact
- Affected specs: plugin-configuration-ui, agent-config, agent-configuration, device-inventory, endpoint-software-inventory, vulnerability-feed-management, observability-signals, trivy-nats-ingestion, build-web-ui
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/plugins/addon_profile.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/addon_profile_ops.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/addon_profile_reconciler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/endpoint_inventory_*`
  - `elixir/serviceradar_core/lib/serviceradar/observability/threat_intel_*`
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/**`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/endpoint_inventory_vulnerability_risk.ex`
  - `go/pkg/addon/advisory_contract.go`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/addon_package_live/index.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/devices/*`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/security/*`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/*`
  - `addons/endpoint-inventory/**`
  - New scanner package implementation under `addons/**` or the Wasm plugin catalog wrapping OSV ScaLibr as the first endpoint inventory scanner.
- Related active changes:
  - `add-addon-profile-targeting` defines the base native add-on profile model.
  - `add-endpoint-sbom-inventory` defines the endpoint software inventory storage and query architecture.
  - `add-cti-signal-coverage` defines the broader CTI and vulnerability matching direction; this change narrows the first operational endpoint vulnerability feed path.
