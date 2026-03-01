## Context

ServiceRadar is a multi-vendor, distributed network monitoring platform. NetworkOptimizer is a single-vendor (UniFi) network optimization tool. The goal is not to clone NetworkOptimizer, but to extract the WiFi analytics and discovery patterns that are vendor-agnostic in concept and adapt them to ServiceRadar's architecture.

Key constraint: ServiceRadar must remain vendor-neutral. WiFi analytics should work with data from any controller API (UniFi, Aruba, Meraki, etc.) or from SNMP wireless MIBs. The UniFi integration is the first implementation, but the data model and analytics engine must be generic.

### Stakeholders
- Network operators managing mixed wired/wireless infrastructure
- MSPs monitoring multiple customer sites with different vendor equipment
- Enterprise IT teams needing WiFi performance visibility

## Goals / Non-Goals

### Goals
- Add WiFi analytics as a first-class capability in ServiceRadar
- Improve discovery engine with API-driven discovery alongside SNMP
- Track wireless clients as entities with signal quality history
- Provide actionable WiFi optimization recommendations
- Keep all new capabilities vendor-agnostic at the data model layer

### Non-Goals
- Replicate NetworkOptimizer's entire feature set (security audit, SQM, speed testing)
- Build a floor plan editor or manual RF propagation simulator (too UI-heavy for initial scope)
- Support UniFi-specific device management actions (firmware upgrades, provisioning)
- Replace the existing SNMP-based discovery engine (complement, not replace)

## Decisions

### D1: Vendor-agnostic WiFi data model with controller adapters

**Decision**: Define a generic WiFi data model (AccessPoint, WirelessClient, RadioState, ChannelObservation) in Ash resources. Controller-specific adapters (UniFi first, then Aruba/Meraki) translate vendor API responses into the generic model.

**Why**: ServiceRadar's value is multi-vendor. Locking WiFi analytics to UniFi would be a strategic mistake.

**Alternatives considered**:
- Direct UniFi-only integration: Faster to build, but creates tech debt and limits market.
- SNMP-only wireless MIBs: Too limited - most WiFi-specific data (client RSSI, channel utilization, roaming) requires controller APIs.

### D2: WiFi analytics in Elixir, not Go

**Decision**: WiFi analytics (channel analysis, scoring, recommendations) live in Elixir/Ash in `serviceradar_core`, not in the Go agent/mapper.

**Why**: Analytics need access to historical data in CNPG/TimescaleDB, Ash resources for persistence, and Oban for scheduling. The Go agent collects raw data; Elixir analyzes it.

**Alternatives considered**:
- Go-based analytics in the agent: Would require duplicating DB access and complicate the agent. Agent should stay focused on collection.
- Rust NIF for analytics: Over-engineering for analysis that's mostly aggregations and comparisons.

### D3: API discovery as a mapper plugin mode

**Decision**: Add API discovery as a mode in the existing mapper job framework. A mapper job can be configured with `discovery_mode: "api"` (vs existing `"snmp"`) and includes controller connection settings. The Go mapper's `ubnt_poller.go` handles the API calls, and results flow through the same ingestion pipeline.

**Why**: Reuses existing job scheduling, agent dispatch, result streaming, and ingestion infrastructure. No new services needed.

**Alternatives considered**:
- Separate API discovery service: More isolation, but adds operational complexity and duplicates infrastructure.
- Elixir-side API polling (skip the agent): Loses the distributed agent advantage - can't reach controllers behind NATs/firewalls.

### D4: Wireless clients as OCSF devices with WiFi extension

**Decision**: Wireless clients are stored in the same `ocsf_devices` table with `type_id` appropriate to their device type. WiFi-specific metadata (RSSI, SSID, WiFi generation, AP association) stored in a related `wireless_client_observations` hypertable for time-series tracking.

**Why**: Clients ARE devices - they should be in the device inventory for search, grouping, and correlation. Time-series observations handle the high-frequency signal data without bloating the device table.

**Alternatives considered**:
- Separate wireless_clients table: Creates a parallel inventory, duplicates search/filter logic, harder to correlate with wired device data.
- Everything in device JSONB: Signal history would bloat device records; time-series queries would be slow.

### D5: Channel analysis uses collected AP radio state, not real-time scanning

**Decision**: Channel analysis works from periodically collected AP radio state data (current channel, TX power, utilization, noise floor) stored in TimescaleDB. Analysis runs as an Oban job producing recommendations.

**Why**: Real-time scanning would require AP-side agents or specialized hardware. Periodic collection from controller APIs gives 95% of the value with zero additional infrastructure.

**Alternatives considered**:
- Real-time spectrum analysis: Requires dedicated hardware (spectrum analyzers). Out of scope.
- Agent-side WiFi scanning: Would require agents on APs, which isn't practical for most deployments.

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │              Web-NG (LiveView)           │
                    │  ┌─────────┐ ┌──────────┐ ┌──────────┐ │
                    │  │ Channel │ │ Client   │ │ AP Load  │ │
                    │  │ Analysis│ │ Stats    │ │ Balance  │ │
                    │  └────┬────┘ └────┬─────┘ └────┬─────┘ │
                    └───────┼───────────┼────────────┼────────┘
                            │           │            │
                    ┌───────┴───────────┴────────────┴────────┐
                    │           Core-Elx (Ash/Oban)            │
                    │  ┌──────────────────────────────────┐   │
                    │  │     WiFi Analytics Domain         │   │
                    │  │  - ChannelAnalyzer                │   │
                    │  │  - LoadBalanceAnalyzer             │   │
                    │  │  - RoamingTracker                  │   │
                    │  │  - SiteHealthScorer                │   │
                    │  └──────────────┬───────────────────┘   │
                    │                 │                         │
                    │  ┌──────────────┴───────────────────┐   │
                    │  │     WiFi Ash Resources             │   │
                    │  │  - AccessPointRadio                │   │
                    │  │  - WirelessClientObservation       │   │
                    │  │  - ChannelObservation              │   │
                    │  │  - WiFiSiteHealth                  │   │
                    │  └──────────────┬───────────────────┘   │
                    └─────────────────┼────────────────────────┘
                                      │
                    ┌─────────────────┼────────────────────────┐
                    │          CNPG / TimescaleDB               │
                    │  ┌──────────────┴───────────────────┐   │
                    │  │  ap_radio_states (hypertable)      │   │
                    │  │  wireless_client_obs (hypertable)  │   │
                    │  │  channel_observations (hypertable) │   │
                    │  │  wifi_site_health (hypertable)     │   │
                    │  └───────────────────────────────────┘   │
                    └──────────────────────────────────────────┘
                                      ▲
                                      │ gRPC stream
                    ┌─────────────────┼────────────────────────┐
                    │          Agent (Go mapper)                │
                    │  ┌──────────────┴───────────────────┐   │
                    │  │  API Discovery Mode                │   │
                    │  │  ┌────────────┐ ┌──────────────┐ │   │
                    │  │  │ UniFi      │ │ Aruba        │ │   │
                    │  │  │ Adapter    │ │ Adapter      │ │   │
                    │  │  │ (ubnt_     │ │ (future)     │ │   │
                    │  │  │ poller.go) │ │              │ │   │
                    │  │  └────────────┘ └──────────────┘ │   │
                    │  └───────────────────────────────────┘   │
                    │  ┌───────────────────────────────────┐   │
                    │  │  SNMP Discovery Mode (existing)    │   │
                    │  └───────────────────────────────────┘   │
                    └──────────────────────────────────────────┘
```

### Data Flow

1. **Collection**: Go agent polls UniFi controller API (or SNMP wireless MIBs) on schedule
2. **Streaming**: Results stream to agent-gateway via gRPC (existing pipeline)
3. **Ingestion**: Core-elx ingests into Ash resources → TimescaleDB hypertables
4. **Analysis**: Oban jobs run WiFi analytics periodically (channel analysis, scoring, etc.)
5. **Presentation**: LiveView dashboards query Ash resources for real-time display

### Proto Extensions (discovery.proto)

New message types needed:
- `WirelessClient` - client MAC, IP, SSID, BSSID, signal, noise, tx_rate, rx_rate, wifi_generation, channel, band
- `AccessPointRadio` - AP MAC, radio band, channel, channel_width, tx_power, utilization, noise_floor, client_count
- `ControllerDiscoveryConfig` - controller type, URL, credentials ref, site filter
- `WiFiDiscoveryResult` - collection of AP radios + wireless clients from a single poll

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| UniFi API is undocumented and changes between firmware versions | NetworkOptimizer's approach (hybrid DTO + JsonElement) handles this; we can use similar defensive parsing with Go's json.RawMessage |
| WiFi data volume could be high (signal observations per client per minute) | Use TimescaleDB hypertables with aggressive retention policies; downsample after 24h |
| Controller API rate limiting | Configurable poll intervals; respect controller rate limits; cache responses |
| Vendor lock-in concern from teams | Generic data model with adapters addresses this; document the abstraction |
| Scope creep into floor plan / RF simulation | Explicitly out of scope; signal heatmaps use collected data only, no propagation modeling |

## Migration Plan

No migration needed - this is purely additive. New tables, new Ash resources, new proto messages. Existing discovery continues to work unchanged.

### Rollout Strategy
1. Phase 1 (UniFi API discovery) can be deployed independently - it just adds richer data to existing mapper results
2. Phase 2 (WiFi analytics) requires Phase 1 data but doesn't change existing behavior
3. Phase 3 (RF/coverage) builds on Phase 2 signal history data
4. Phase 4 (discovery improvements) can be done in parallel with Phase 2-3

## Open Questions

1. **How granular should wireless client observation intervals be?** NetworkOptimizer doesn't specify, but for roaming analysis, sub-minute resolution may be needed. Suggest: configurable, default 60s, min 15s.
2. **Should we support SNMP wireless MIBs (IEEE 802.11 MIB) as a fallback for non-controller-managed APs?** This would give basic WiFi data from any vendor without API integration. Suggest: yes, as Phase 5 stretch goal.
3. **How should WiFi analytics interact with the existing zen rules engine?** Suggest: WiFi analyzers produce "findings" that can trigger zen rules (e.g., "AP utilization > 80%" fires a zen rule).
4. **Should wireless clients count toward device inventory limits / licensing?** Need product decision - they can be 10-100x the infrastructure device count.
