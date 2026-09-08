# Change: Add UniFi WiFi analytics and discovery parity with NetworkOptimizer

## Why

A comprehensive gap analysis between ServiceRadar and NetworkOptimizer (a .NET/Blazor UniFi network management tool) reveals three critical capability gaps that affect ServiceRadar's value proposition for environments with wireless infrastructure:

1. **Discovery engine blind spots**: ServiceRadar's mapper has strong SNMP/LLDP/CDP discovery, but lacks API-driven discovery that pulls rich metadata directly from controller platforms (UniFi, Aruba, Meraki). NetworkOptimizer achieves zero-disruption discovery purely via UniFi API, getting client lists, firmware states, uplink hierarchies, and VLAN configurations without a single SNMP packet. ServiceRadar already has a `ubnt_poller.go` integration, but it only scratches the surface of what the UniFi API exposes.

2. **No WiFi analytics**: ServiceRadar can detect wireless interfaces via SNMP but has zero WiFi-specific analytics. NetworkOptimizer provides a 12-tab WiFi optimization suite: channel recommendations, RF interference analysis, AP load balancing, band steering, airtime fairness, roaming tracking, and signal heatmaps. For any deployment with wireless infrastructure, this is a glaring gap.

3. **Wireless client visibility**: ServiceRadar tracks devices at the infrastructure level but has no concept of wireless clients, their signal quality, roaming behavior, or connection statistics. NetworkOptimizer tracks every wireless client with RSSI history, WiFi generation, roaming timeline, and AP association.

The biggest pain point in our own implementation is the **discovery/mapper engine** - specifically around the quality and completeness of discovered topology data. NetworkOptimizer's API-driven approach is complementary to our SNMP-based engine and provides lessons for improving identity resolution, client discovery, and metadata enrichment.

## What Changes

### Phase 1: Enhanced UniFi API Discovery (complement existing SNMP mapper)
- Deepen `ubnt_poller.go` to pull full device hierarchy, client lists, network configs, and VLAN assignments from UniFi controllers
- Add wireless client discovery as a first-class entity (not just infrastructure devices)
- Ingest UniFi device fingerprint database for richer device classification
- Pull firmware state, upgrade eligibility, and adoption status
- Extract uplink topology (which AP connects to which switch on which port)

### Phase 2: WiFi Analytics Engine
- Add WiFi-specific Ash resources for AP radio state, channel utilization, client signal history
- Build channel analysis: overlap detection, co-channel interference scoring, regulatory-aware recommendations
- AP load balancing analysis: client distribution across APs, airtime utilization
- Band steering analysis: 2.4 GHz vs 5 GHz vs 6 GHz distribution
- Roaming tracking: client AP transitions, roaming frequency, sticky client detection
- WiFi client statistics dashboard: signal strength, WiFi generation, connection quality

### Phase 3: RF Environment & Coverage Analysis
- Signal strength heatmap data collection (RSSI per client per AP over time)
- Coverage gap detection from client signal data
- TX power analysis and recommendations
- Airtime fairness analysis (legacy vs modern client impact)
- WiFi site health scoring (composite metric from coverage, capacity, interference, roaming health)

### Phase 4: Discovery Engine Improvements (lessons from NetworkOptimizer)
- API-driven discovery as a first-class discovery mode alongside SNMP
- Controller-mediated topology (use controller's knowledge of device hierarchy)
- Client-as-endpoint promotion (wireless/wired clients become inventory entries with confidence scoring)
- Multi-source device fingerprinting (SNMP sysDescr + controller fingerprint DB + MAC OUI)
- Offline client tracking (last-seen, last-VLAN, last-IP for devices that disconnect)

## Impact
- Affected specs:
  - `network-discovery` (new API discovery mode, client discovery, fingerprinting)
  - `device-inventory` (wireless client entity, WiFi metadata, fingerprint enrichment)
  - New spec: `wifi-analytics` (all WiFi-specific analysis capabilities)
- Affected code:
  - `go/pkg/mapper/ubnt_poller.go` - Major expansion of UniFi API coverage
  - `go/pkg/mapper/discovery.go` - API discovery mode integration
  - `go/pkg/mapper/types.go` - New wireless client types, WiFi metadata
  - `proto/discovery/discovery.proto` - Wireless client messages, WiFi metrics
  - `elixir/serviceradar_core/lib/serviceradar/inventory/` - Wireless client Ash resources
  - `elixir/serviceradar_core/lib/serviceradar/wifi/` - New WiFi analytics domain
  - `elixir/web-ng/` - WiFi analytics dashboard LiveViews
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/` - Client ingestion, fingerprint enrichment

## Gap Analysis Summary

| Capability | NetworkOptimizer | ServiceRadar | Gap |
|---|---|---|---|
| UniFi device discovery | Full API (devices, clients, networks, firewall) | Basic device/interface via ubnt_poller | **Large** |
| SNMP discovery | v1/v2c/v3 polling | v1/v2c/v3 + LLDP/CDP/ARP/bridge tables | SR ahead |
| Topology building | API-driven hierarchy | SNMP/LLDP/CDP + AGE graph | Different approaches, complementary |
| WiFi channel analysis | 12-tab suite with recommendations | None | **Critical** |
| Wireless client tracking | Full (RSSI, roaming, WiFi gen, history) | None | **Critical** |
| RF heatmap / coverage | Floor plan + signal propagation model | None | **Critical** |
| AP load balancing | Client distribution + airtime analysis | None | **Large** |
| Band steering analysis | 2.4/5/6 GHz distribution + recommendations | None | **Large** |
| Roaming tracking | AP transition timeline + sticky detection | None | **Large** |
| Device fingerprinting | UniFi DB + MAC OUI + name patterns | SNMP sysDescr + OCSF classification | **Medium** |
| Security auditing | 63-point audit (firewall, VLAN, DNS, UPnP) | NetFlow port scan detection | Different scope |
| Speed testing | WAN (CloudFlare) + LAN (iperf3) + browser | rperf proto defined | **Medium** |
| Threat intelligence | IPS logs + CrowdSec CTI + kill chain | NetFlow anomaly detection | Different scope |
| SQM / bufferbloat | Auto-deploy via SSH | None | Out of scope |
| Alerting | WiFi-specific + speed regression + audit score | Zen rules engine (generic) | **Small** (extend zen rules) |
| Multi-vendor support | UniFi only | SNMP-based (any vendor) | SR ahead |
| Distributed architecture | Single instance | Agents + gateways + mTLS | SR ahead |
| Flow analytics | None | NetFlow v5/v9 + sFlow + BMP | SR ahead |
| Graph topology | None | Apache AGE property graph | SR ahead |

### What NOT to adopt (out of scope / different product direction)
- **Security auditing suite**: NetworkOptimizer's 63-point audit is deeply UniFi-specific (firewall rules, UPnP, DNS config). ServiceRadar's approach should be vendor-agnostic via zen rules.
- **SQM/bufferbloat management**: Too device-specific (SSH into gateways). Not aligned with ServiceRadar's monitoring-first approach.
- **Speed testing infrastructure**: While useful, this is a separate concern. The existing rperf proto can be expanded independently.
- **Threat intelligence / IPS integration**: ServiceRadar already has netflow-based detection; IPS log ingestion is a separate, smaller proposal.
- **PDF report generation**: Can be added independently; not tied to WiFi/discovery.
