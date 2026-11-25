## 0. Hardware spikes (gate the broker, TLS, codec and storage decisions)

Captures answer questions only. No captured value is committed (design D12).

- [ ] 0.1 Register a DJI developer Cloud API app and an Open API key for the lab.
- [ ] 0.2 S1: capture MQTT CONNECT and SUBSCRIBE from a Dock 2 or Dock 3, an O4 Ground Station (if available) and Pilot 2 on RC Plus 2. Record:
  - protocol level
  - QoS, retain and Will flags
  - whether Pilot needs `tcp://` or `ws(s)://`
  - whether Pilot accepts an API base URL with a path prefix
  - the real OSD rate
  - whether license verification needs internet access
- [ ] 0.3 S2: test dock and Pilot MQTT 8883 against a Let's Encrypt chain and a private CA. Record which chains each gateway accepts.
- [ ] 0.4 S3: record the RTMP codec, profile and B-frame use per model (Dock 2/3/4 cameras, M4E on RC Plus 2) at each `video_quality`. Test WHIP publish from a Dock 3.
- [ ] 0.5 S4: verify devices upload to a custom S3-compatible endpoint with `provider: minio` and path-style addressing.
- [ ] 0.6 Record S1-S4 results in `design.md` and resolve D2 (NATS MQTT vs gateway-hosted MQTT 5).

## 1. Gateway foundation (phase 1)

- [ ] 1.1 Scaffold `rust/dji-gateway` with Bazel and Cargo. Add the envelope types, topic mapping, `tid`/`bid` correlation and service-call timeouts.
- [ ] 1.2 Implement the request handlers:
  - `config` (license and NTP)
  - `airport_bind_status`
  - `airport_organization_get`
  - `airport_organization_bind`
  - `sys/product/{gw}/status` replies
- [ ] 1.3 Add a credential broker grant for the `dji_cloud_api` and `dji_open_api` integration credentials. Add both descriptors to the credentials settings area.
- [ ] 1.4 Add `platform.dji_gateway_enrollments` (Ash resource and migration): Argon2id hash, binding code, label, expiry, multi-gateway flag, first-bound serial. Add a web-ng enrollment UI that shows values once.
- [ ] 1.5 Device-facing MQTT, depending on the S1 result:
  - If NATS: add the chart `mqtt {}` block with its own TLS, the `DJI` account with JetStream, and exports and imports. Add the callout password-grant path with per-gateway permissions and revocation KICK.
  - Otherwise: add a gateway-hosted MQTT 5 broker with the same grants.
- [ ] 1.6 Add the internal gRPC API (mTLS / SPIFFE) for Core: `StartLivePush`, `StopLivePush`, `SetLiveQuality`, `ChangeLens`, `ListLogs`, `PullLogs`, `GetCapabilities`.
- [ ] 1.7 Add a protocol simulator with invented serials (dock, O4, Pilot gateway) driving topology, OSD, state, HMS, binding and RTMP push. Wire it into gateway tests.

## 2. Inventory, telemetry and events (phase 1)

- [ ] 2.1 Add a `dji` HardwareSerial namespace and `dji:v1:<sn>` integration identity. Add DIRE tests proving:
  - an aircraft resolves to one device across gateways
  - no address-based merge happens
- [ ] 2.2 Add the `platform.dji_devices` sibling resource and migration, the model-key table (public DJI product table) and the `management_device_id` gateway relation.
- [ ] 2.3 Turn topology into complete-snapshot `device_discovery` records, with offline marking for absent sub-devices.
- [ ] 2.4 Add the OSD/state metric catalog, emitting `serviceradar.metric.v1` through JetStream with the rate cap. Run the EventWriter path on both telemetry backends.
- [ ] 2.5 Emit positions as spatial observations once #4911 is available. Until then, emit interim gauges plus the current position on `dji_devices`.
- [ ] 2.6 Add the HMS full-set diff, emitting OCSF raise and clear events with a signal schema and condition keys. Vendor an `hms.json` snapshot and refresh it through `EgressClient`. Add default alert rules, created disabled.
- [ ] 2.7 Create `Camera.Source` (`ingest_mode: push`) and `StreamProfile` rows from `live_capacity`, with no stream addresses.

## 3. Push video ingest (phase 1)

- [ ] 3.1 Add `RelaySession.origin` (migration and Ash) with `agent_pull` as the default for existing rows.
- [ ] 3.2 RTMP ingest in core-elx:
  - `Membrane.RTMPServer` listener
  - FLV to Annex-B conversion and ms to 90 kHz rescaling
  - emission into `Pipeline` through the chunk seam
  - token and key validation against the session or source
- [ ] 3.3 Push-orchestrated open, activate and teardown: token mint and hash, gateway `StartLivePush` / `StopLivePush`, recorder lease interaction.
- [ ] 3.4 Source-initiated keys: show-once, hashed, rotatable, offline state when there is no publisher. Show the published endpoint in the source UI.
- [ ] 3.5 Add the HEVC path to `Membrane.FLV.Demuxer`. Carry it as a vendored patch, open the upstream PR, and add bounded H.265 to H.264 transcoding with relay metrics.
- [ ] 3.6 Detect frame reordering and mark such profiles not recordable, with a visible reason.
- [ ] 3.7 Chart: Gateway API TCP listener and TCPRoute for RTMP 1935, and optional RTMPS.

## 4. Enablement, UI and hosted rollout (phase 1)

- [ ] 4.1 Add the `DjiFleetSettings` runtime settings resource and the web-ng settings page with published endpoints, defaulting to disabled.
- [ ] 4.2 Chart: the `dji-gateway` workload, and the MQTT 8883 listener and route.
- [ ] 4.3 Add MQTT and RTMP endpoint facts to the hosted runtime contract.
- [ ] 4.4 Add the `in:drones` SRQL entity (rust/srql and the web-ng catalog and entity access).
- [ ] 4.5 Add the device detail "Drone" tab.
- [ ] 4.6 Add the first-party `drone-fleet` dashboard package with a map, fleet table, dock environment, HMS feed and camera grid.
- [ ] 4.7 Write the companion change in `carverauto/serviceradar-control`, covering:
  - entitlement
  - chart gate
  - endpoint contract
  - exposure kinds, DNS and SANs
  - public firewall opt-in
  - setting-to-re-render signal
  - TURN for hosted tenants
- [ ] 4.8 Add operator docs: enrolling a dock (Dock 1/2 through Pilot, Dock 3/O4 through the DJI Industrial App), the coverage matrix, and troubleshooting.

## 5. DJI Pilot 2 (phase 2)

- [ ] 5.1 Add the web-ng `/dji/pilot` H5 page with license verification, ServiceRadar login, the `drones.pilot.connect` permission, and Pilot session token and MQTT credential minting.
- [ ] 5.2 Add the gateway Pilot HTTPS module endpoints (`storage`, `media`, `manage`, minimal `map`) and the WebSocket push, with HTTPRoutes.
- [ ] 5.3 Add Pilot liveshare (video-on-demand) through push-orchestrated sessions.

## 6. Media, logs and flight records (phase 3)

- [ ] 6.1 Add the S3-compatible intake (`s3s`): minted prefix-scoped upload credentials, streaming to the configured object storage, and `storage_config_get` / Pilot `sts`.
- [ ] 6.2 Add the `platform.dji_media_files` catalog from `file_upload_callback`, and the `in:drone_media` SRQL entity.
- [ ] 6.3 Add device log list and pull with progress, opaque storage and download.
- [ ] 6.4 Add flight record parsing with `dji-log-parser` and keychain caching. Handle Dock 4 `module` 2, manual and consumer import, and unsupported-format reporting. Upstream fixes for formats it cannot read.

## 7. WHIP and onboard AI (phase 4)

- [ ] 7.1 Add the WHIP ingest (`membrane_webrtc_plugin` WHIP server) with token-in-URL auth and UDP exposure. Gate it for hosted tenants on UDP availability.
- [ ] 7.2 Add a DJI SEI (0xF5) parser that turns onboard detections into camera observations.
- [ ] 7.3 Make WHIP the preferred `url_type` where `live_capacity` and the installation allow it.

## 8. Validation

- [ ] 8.1 Run `openspec validate add-dji-drone-fleet-integration --strict`.
- [ ] 8.2 Simulator end-to-end:
  - enrollment, binding, inventory, metrics, HMS raise and clear
  - RTMP live view
  - NVR recording of a pushed stream
  - semantic search over that recording
- [ ] 8.3 Lab hardware acceptance on Dock 3 and RC Plus 2: inventory, telemetry, HMS and live view. Commit no captured data.
