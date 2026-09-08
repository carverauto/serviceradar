## Phase 1: Enhanced UniFi API Discovery

### 1.1 Expand UniFi API client in Go mapper
- [ ] 1.1.1 Audit current `ubnt_poller.go` coverage against NetworkOptimizer's `UniFiApiClient.cs` (2349 lines) - document every API endpoint we're missing
- [ ] 1.1.2 Add UniFi client discovery: `GET /api/s/{site}/stat/sta` (connected clients) and `GET /api/s/{site}/rest/user` (all known clients including offline)
- [ ] 1.1.3 Add UniFi network config fetching: `GET /api/s/{site}/rest/networkconf` (VLANs, DHCP, subnets)
- [ ] 1.1.4 Add UniFi site health: `GET /api/s/{site}/stat/health` (subsystem health metrics)
- [ ] 1.1.5 Add firmware state extraction: upgradable flag, current/available firmware versions per device
- [ ] 1.1.6 Add device uplink hierarchy extraction: parse `uplink` object from device stat to build switch→AP topology
- [ ] 1.1.7 Handle both UniFi OS (`/proxy/network/api/`) and standalone (`/api/`) endpoint paths
- [ ] 1.1.8 Implement defensive JSON parsing (use `json.RawMessage` for variable fields, typed structs for stable fields) following NetworkOptimizer's hybrid DTO pattern
- [ ] 1.1.9 Add automatic re-authentication on 401/403 (cookie-based auth can expire mid-session)
- [ ] 1.1.10 Add support for self-signed certificates (skip-verify option in controller config)

### 1.2 Proto extensions for wireless data
- [ ] 1.2.1 Add `WirelessClient` message to `discovery.proto`: mac, ip, hostname, ssid, bssid, signal, noise, tx_rate, rx_rate, wifi_generation, channel, band, vlan_id, is_guest, uptime, bytes_tx, bytes_rx
- [ ] 1.2.2 Add `AccessPointRadio` message: ap_mac, radio_name, band (2g/5g/6g), channel, channel_width, tx_power, utilization_pct, noise_floor, client_count, satisfaction_pct
- [ ] 1.2.3 Add `ControllerDiscoveryConfig` message: controller_type (unifi/aruba/meraki), url, site_filter, credential_ref
- [ ] 1.2.4 Add `WiFiDiscoveryResult` wrapper message containing repeated AccessPointRadio + repeated WirelessClient
- [ ] 1.2.5 Extend `DiscoveryResult` to include optional `WiFiDiscoveryResult`

### 1.3 Wireless client ingestion in Elixir
- [ ] 1.3.1 Create `WirelessClientObservation` Ash resource (hypertable: timestamp, client_mac, ap_mac, ssid, bssid, signal_dbm, noise_dbm, tx_rate_mbps, rx_rate_mbps, wifi_generation, channel, band, vlan_id, bytes_tx, bytes_rx)
- [ ] 1.3.2 Create `AccessPointRadio` Ash resource (hypertable: timestamp, ap_mac, ap_device_uid, radio_name, band, channel, channel_width, tx_power_dbm, utilization_pct, noise_floor_dbm, client_count)
- [ ] 1.3.3 Extend `MapperResultsIngestor` to process `WiFiDiscoveryResult` payloads
- [ ] 1.3.4 Add wireless client → DIRE device promotion: create/update OCSF device entries for wireless clients with type_id based on UniFi fingerprint (Mobile=5, Laptop=3, IoT=7, etc.)
- [ ] 1.3.5 Add client last-seen tracking: update device `last_seen_at` on each observation, track `last_ap_mac`, `last_ssid`, `last_vlan_id`
- [ ] 1.3.6 Configure TimescaleDB retention policies for observation hypertables (default: 7 days raw, 90 days downsampled)

### 1.4 Device fingerprint enrichment
- [ ] 1.4.1 Ingest UniFi fingerprint data from device/client API responses (device category, OS family, device name)
- [ ] 1.4.2 Add MAC OUI lookup table (IEEE registration authority data) for vendor identification
- [ ] 1.4.3 Implement multi-source fingerprint merge: SNMP sysDescr + UniFi fingerprint + MAC OUI → best-effort device classification
- [ ] 1.4.4 Map fingerprint results to OCSF type_id classifications

## Phase 2: WiFi Analytics Engine

### 2.1 Channel analysis
- [ ] 2.1.1 Create `ServiceRadar.WiFi` Ash domain with analytics resources
- [ ] 2.1.2 Implement channel overlap detection: given AP radio states, identify APs on same/overlapping channels within RF proximity
- [ ] 2.1.3 Implement co-channel interference scoring: quantify the severity of channel overlap based on signal strength overlap
- [ ] 2.1.4 Implement adjacent-channel interference detection for 2.4 GHz (channels 1-11 overlap unless 5+ apart)
- [ ] 2.1.5 Build channel recommendation engine: given current AP assignments, suggest optimal channel per AP considering regulatory domain, AP hardware capabilities, and neighbor AP channels
- [ ] 2.1.6 Add 6 GHz preferred scanning channel filtering (WiFi 6E/7)
- [ ] 2.1.7 Create Oban worker for periodic channel analysis (configurable schedule, default: every 4 hours)

### 2.2 AP load balancing analysis
- [ ] 2.2.1 Calculate per-AP client count and client density relative to AP capability
- [ ] 2.2.2 Calculate airtime utilization distribution across APs
- [ ] 2.2.3 Detect load imbalance: flag when any AP has >2x the average client count or utilization
- [ ] 2.2.4 Generate load balancing recommendations (enable band steering, adjust min-RSSI, etc.)

### 2.3 Band steering analysis
- [ ] 2.3.1 Calculate client distribution across 2.4 GHz / 5 GHz / 6 GHz per SSID
- [ ] 2.3.2 Detect high 2.4 GHz concentration (>40% of clients on 2.4 GHz when 5 GHz available)
- [ ] 2.3.3 Identify dual-band capable clients stuck on 2.4 GHz
- [ ] 2.3.4 Generate band steering recommendations

### 2.4 Wireless client statistics
- [ ] 2.4.1 WiFi generation breakdown: count clients by 802.11a/n/ac/ax/be across site
- [ ] 2.4.2 Per-client signal history: RSSI trend over time from `wireless_client_observations`
- [ ] 2.4.3 Client connection quality scoring: composite of signal strength, TX/RX rate, retry rate
- [ ] 2.4.4 Legacy client detection: identify 802.11n-only or 802.11a-only clients that may drag down airtime efficiency
- [ ] 2.4.5 Online/offline client tracking with last-seen metadata

### 2.5 Roaming analysis
- [ ] 2.5.1 Detect AP transitions: when a client's associated AP changes between observations
- [ ] 2.5.2 Build roaming timeline per client: sequence of (timestamp, from_ap, to_ap, signal_before, signal_after)
- [ ] 2.5.3 Calculate roaming frequency per client (roams/hour)
- [ ] 2.5.4 Detect sticky clients: clients with poor signal that should roam but don't
- [ ] 2.5.5 Detect excessive roamers: clients bouncing between APs too frequently

## Phase 3: RF Environment & Site Health

### 3.1 Signal quality analysis
- [ ] 3.1.1 Aggregate RSSI distribution per AP: histogram of client signal strengths
- [ ] 3.1.2 Detect coverage gaps: APs where >20% of clients have signal below -75 dBm
- [ ] 3.1.3 TX power analysis: flag APs with unnecessarily high TX power (causes co-channel interference) or too low (coverage gaps)
- [ ] 3.1.4 Noise floor trending: track noise floor per radio over time, detect interference events

### 3.2 Airtime fairness
- [ ] 3.2.1 Calculate airtime consumption by WiFi generation (legacy vs modern)
- [ ] 3.2.2 Detect legacy devices consuming disproportionate airtime
- [ ] 3.2.3 Recommend isolating legacy clients to dedicated 2.4 GHz SSID
- [ ] 3.2.4 Per-AP airtime efficiency scoring

### 3.3 WiFi site health scoring
- [ ] 3.3.1 Define composite health score (0-100) from weighted dimensions: coverage quality (25%), capacity headroom (20%), interference level (20%), roaming health (15%), client satisfaction (20%)
- [ ] 3.3.2 Implement scoring as Oban job that persists `WiFiSiteHealth` snapshots to hypertable
- [ ] 3.3.3 Trend site health over time for regression detection
- [ ] 3.3.4 Break down score by dimension for actionable diagnostics

### 3.4 WiFi analytics LiveView dashboard
- [ ] 3.4.1 Channel map visualization: which APs on which channels with overlap indicators
- [ ] 3.4.2 Client statistics table: sortable/filterable list of wireless clients with signal, AP, SSID, WiFi generation
- [ ] 3.4.3 AP load balance view: bar chart of client count / utilization per AP
- [ ] 3.4.4 Site health score card with dimension breakdown
- [ ] 3.4.5 Roaming timeline view for selected client
- [ ] 3.4.6 Band distribution pie chart per SSID
- [ ] 3.4.7 Signal strength distribution histogram per AP

## Phase 4: Discovery Engine Improvements

### 4.1 API discovery mode in mapper
- [ ] 4.1.1 Add `discovery_mode` field to mapper job config: `snmp`, `api`, or `hybrid` (both)
- [ ] 4.1.2 In `hybrid` mode: run API discovery first for rich metadata, then SNMP for additional detail (interface counters, bridge tables)
- [ ] 4.1.3 Merge API-discovered topology with SNMP-discovered topology: use controller's uplink hierarchy as authoritative, enrich with LLDP/CDP neighbor data
- [ ] 4.1.4 Add controller-mediated device→port mapping: which device is connected to which switch port (from UniFi's device stat)

### 4.2 Client-as-endpoint promotion
- [ ] 4.2.1 Define confidence scoring for client→device promotion: API fingerprint (high), MAC OUI match (medium), IP-only (low)
- [ ] 4.2.2 Promote wireless clients to OCSF devices via DIRE with appropriate confidence
- [ ] 4.2.3 Promote wired clients observed via controller API (MAC + port + VLAN) to OCSF devices
- [ ] 4.2.4 Track offline clients: preserve last-known state when client disconnects, update `last_seen_at`

### 4.3 Multi-source identity resolution improvements
- [ ] 4.3.1 Add UniFi device adoption MAC as identity signal in DIRE (stable across reboots/re-IPs)
- [ ] 4.3.2 Use controller's device name as authoritative name (user-assigned in UniFi UI)
- [ ] 4.3.3 Cross-reference SNMP-discovered devices with API-discovered devices by MAC address for deduplication
- [ ] 4.3.4 Handle multi-IP devices: UniFi devices may have management IP different from SNMP-reachable IP

### 4.4 Discovery UI enhancements
- [ ] 4.4.1 Add "API Discovery" mode option in discovery job creation UI
- [ ] 4.4.2 Add controller connection settings form (URL, credentials, site selection)
- [ ] 4.4.3 Add controller connection test button (verify API access before saving)
- [ ] 4.4.4 Show wireless clients in discovery results alongside infrastructure devices
- [ ] 4.4.5 Add WiFi analytics link from discovered AP devices
