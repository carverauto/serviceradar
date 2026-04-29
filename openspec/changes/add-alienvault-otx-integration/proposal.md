# Change: Add STIX/TAXII threat intelligence ingestion with AlienVault OTX

## Why
ServiceRadar already stores and analyzes NetFlow telemetry and runs sandboxed Wasm plugins at the edge. A standards-shaped STIX/TAXII threat-intelligence ingestion path can let operators enrich current and historical traffic with external IOCs from AlienVault OTX, CISA, MISP, ISACs, commercial feeds, and customer-local SIEM platforms without hard-coding every source into core.

## What Changes
- Add a threat-intel provider boundary modeled on TAXII 2.1 collections and STIX 2.1 indicator objects.
- Support two provider execution modes:
  - edge Wasm collector plugins assigned to agents, using approved HTTP/TCP/UDP allowlists to reach TAXII servers, AlienVault OTX, and customer-local SIEM APIs.
  - core-hosted sync workers for deployment-level feeds that do not require edge-local reachability.
- Use `serviceradar-sdk-go` for the first built-in edge collector because it is already exercised by existing first-party plugins. The CTI page contract remains SDK-neutral for future Rust collectors.
- Ship AlienVault OTX as the first built-in provider/preset. OTX imports subscribed pulses and IPv4/IPv6/CIDR indicators through the OTX DirectConnect API, translating them into the shared provider boundary.
- Add a normalized CTI ingestion path from plugin results or core workers into CNPG threat-intel tables.
- Extend the existing NetFlow threat-intel settings with provider controls, AlienVault OTX credentials, plugin assignment/status UI, and sync health.
- Reuse `platform.threat_intel_indicators` and `platform.ip_threat_intel_cache` for NetFlow IP/CIDR matching instead of creating a parallel OTX-only match path.
- Add source metadata storage only where needed to explain hits and sync status across STIX/TAXII, OTX, and SIEM-derived indicators.
- Optionally persist raw CTI payload snapshots in NATS Object Store for audit and replay; normalized CNPG rows remain the required query path.
- Improve NetFlow threat-intel matching for current/recent flow data so OTX hits are visible in ServiceRadar without requiring a retroactive-only workflow.
- Add a retroactive hunt mode that can backfill findings across retained NetFlow/DNS history when operators enable or trigger it.
- Add operator visibility for sync health, imported indicator counts, current NetFlow IOC hits, retrohunt status, and findings.

## Impact
- Affected specs: alienvault-otx-threat-intel, wasm-plugin-system, plugin-sdk-go, plugin-sdk-rust, observability-signals, job-scheduling, build-web-ui
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/**`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/**`
  - `go/cmd/wasm-plugins/**`
  - `go/pkg/agent/plugin_runtime.go`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
  - Oban cron/job registry and tests

## Existing Baseline
- `NetflowSettings` already has generic threat-intel toggles and feed URL configuration.
- `ThreatIntelFeedRefreshWorker` already downloads newline-delimited CIDR feeds into `platform.threat_intel_indicators`.
- `NetflowSecurityRefreshWorker` already matches recent flow IPs against `platform.threat_intel_indicators` and writes `IpThreatIntelCache`.
- NetFlow and log flow-detail UIs already show basic source/destination threat-intel hit counts from the cache.
- The Wasm plugin system already supports signed package delivery, explicit HTTP/TCP/UDP allowlists, agent assignment, scheduled execution, and `serviceradar.plugin_result.v1` ingestion.
- The archived `overhaul-netflow-analytics-parity` proposal explicitly called for an OTX provider as a child change. This proposal completes that slice.

## References
- TAXII 2.1 OASIS Standard: https://docs.oasis-open.org/cti/taxii/v2.1/os/taxii-v2.1-os.html
- STIX 2.1 OASIS Standard: https://docs.oasis-open.org/cti/stix/v2.1/os/stix-v2.1-os.html
- AlienVault OTX API docs: https://otx.alienvault.com/api
- AlienVault OTX Python SDK: https://github.com/AlienVault-OTX/OTX-Python-SDK
- ServiceRadar Go SDK: https://code.carverauto.dev/carverauto/serviceradar-sdk-go
- ServiceRadar Rust SDK: https://code.carverauto.dev/carverauto/serviceradar-sdk-rust

## Notes
- The OTX API key must be treated as a secret. It should be entered through encrypted settings or injected from deployment secrets, never committed to the repo.
- The user-provided key in the conversation should be rotated before production use because it has been exposed outside the target secret store.
