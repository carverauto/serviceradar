# Change: Add SNMP fingerprint and topology enrichment

## Why
Issue #2825 highlights that current SNMP-driven enrichment is not extracting enough stable signals to classify devices and topology consistently. We need stronger, deterministic ingestion of standard SNMP identity/bridge/VLAN signals so DIRE and enrichment rules can distinguish router vs AP/bridge vs switch behavior, populate missing inventory metadata, and improve topology quality.

## What Changes
- Extend mapper SNMP polling to capture a normalized device fingerprint from standard MIBs (system, interface, bridge, VLAN) for each discovered device.
- Persist and propagate additional SNMP identity fields (`sysName`, `sysDescr`, `sysObjectID`, `sysContact`/owner, `sysLocation`, `ipForwarding`, `dot1dBaseBridgeAddress`, VLAN membership evidence) in mapper payloads.
- Feed the fingerprint into enrichment rules and role inference so classification uses explicit signals instead of ad-hoc parsing.
- Improve topology link generation by deriving link candidates from bridge/VLAN evidence with deterministic confidence scoring and idempotent graph upserts.
- Surface meaningful SNMP identity fields in device details UI, and use them in inventory fallback display when vendor/type/model are unknown.
- Add a comprehensive regression matrix for Ubiquiti router/switch/AP cases and mixed-vendor devices.

## Impact
- Affected specs:
  - `snmp-checker`
  - `network-discovery`
  - `device-inventory`
  - `age-graph`
- Affected code (expected):
  - `pkg/mapper/snmp_polling.go`
  - mapper discovery protobuf structures and publishing path
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/*` enrichment/rule evaluation modules
  - `elixir/serviceradar_core/lib/serviceradar/topology/topology_graph.ex`
  - `web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex`
  - `web-ng/lib/serviceradar_web_ng_web/live/devices_live/index.ex`
