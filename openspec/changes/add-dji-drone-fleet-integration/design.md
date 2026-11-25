# Design: DJI drone fleet integration

## Context

DJI Cloud API is the only DJI interface that yields full telemetry, health,
live video, media and logs. Version 1.20 was released 2026-11-05. The live docs
are at <https://developer.dji.com/doc/cloud-api-tutorial/en/>. The GitHub mirror
`dji-sdk/Cloud-API-Doc` is stale at v1.11.3 and lacks Dock 3/4, M4D, M400 and
RC Plus 2.

The architecture is gateway-centric. The aircraft talks only to its gateway
over DJI's private link. The gateway is one of:

- a Dock 1, 2 or 3
- an O4 Ground Station, which fronts Dock 4
- an RC running DJI Pilot 2

The gateway connects out to five platform services:

- an MQTT broker
- an HTTPS API (Pilot only)
- a WebSocket service (Pilot only)
- S3-style object storage
- a streaming ingest

Messages use the envelope `{tid, bid, method, timestamp, gateway, data}` on
`thing/product/{sn}/{osd|state|services|services_reply|events|events_reply|requests|requests_reply|property/set|drc/up|drc/down}`
and `sys/product/{gw}/status`.

The platform is an active peer, not only a consumer:

- A dock's first `requests` message is `config`. The platform must reply with
  the App ID, App Key, App License and NTP server, or the dock disconnects.
- Organization binding (`airport_bind_status`, `airport_organization_get`,
  `airport_organization_bind`) and `storage_config_get` are requests the
  platform must answer.
- Topology updates on `sys/product/{gw}/status` require a `status_reply`.

### Supported products (Cloud API v1.20)

| Gateway | Aircraft | Model keys |
|---|---|---|
| Dock 1 | M30 / M30T | 3-1-0, 0-67-0/1 |
| Dock 2 | M3D / M3TD | 3-2-0, 0-91-0/1 |
| Dock 3 | M4D / M4TD | 3-3-0, 0-100-0/1 |
| O4 Ground Station + Dock 4 | M5TD | 8-135-0, 9-131-0, 0-130-0 |
| RC Plus + Pilot 2 | M30 series, M300 RTK, M350 RTK (H20/H30 payloads) | 2-119-0 |
| RC Plus 2 + Pilot 2 | M4E / M4T, M400 (H30 payloads) | 2-174-0 |
| RC Pro Enterprise + Pilot 2 | M3E / M3T / M3TA | 2-144-0 |
| Smart Controller Enterprise + Pilot 2 | M300 RTK | 2-56-0 |

The Cloud API does not reach:

- consumer drones (Mini, Air, Mavic, Avata, Neo, Flip)
- Agras
- FlyCart
- M3M
- mapping payloads P1 / L1 / L2
- third-party payloads

D13 assigns each of these the best available path.

### What ServiceRadar has today

These constraints shape every decision below.

- **Wasm plugins** (wazero, WASI p1) have no listen/accept, no MQTT and no
  persistent state. Each run has a 10 s default timeout. The only long-lived
  modes are the camera media stream and the Proxmox console.
- **Native add-ons** can listen. The OTel and PowerDNS add-ons are the
  precedent.
- **Camera relay** is pull-based and Core-initiated: reserve a `RelaySession`,
  then `camera.open_relay` to an agent, which pulls RTSP and uploads over gRPC
  to agent-gateway, then core-elx `Pipeline`.
  - `Pipeline` starts at `ChunkSource`, which takes `{:media_chunk, %{payload:
    annexb_au, pts, dts, keyframe, codec: "h264", payload_format: "annexb"}}`.
  - Viewers (WebSocket, WebRTC), analysis branches and the recorder `Inbox` all
    hang off that one seam.
  - Recording, the media worker and Vantage accept only H.264 with no frame
    reordering.
- **RTMP and WHIP servers** are already compiled into core-elx but unused:
  - `membrane_rtmp_plugin` 0.29.6 provides `Membrane.RTMPServer`, pulled in by
    the vendored boombox.
  - `membrane_webrtc_plugin` provides a WHIP server.
  - `membrane_flv_plugin` 0.12.0 parses the enhanced-RTMP `hvc1` header but its
    demuxer drops HEVC with `{:unsupported_codec, :HEVC}` (`demuxer.ex:195`).
- **NATS** has no `mqtt {}` listener anywhere.
  - The client port requires mTLS.
  - The auth callout (`ServiceRadar.NATS.ManagedCertificateAuthorization`)
    grants by certificate fingerprint only.
- **Device identity.** DIRE admits integration-id-only devices; the Starlink
  terminals are the precedent. `ocsf_devices.ip` is nullable.
- **Hosted tenants.** Each serviceradar.cloud tenant has a dedicated LKE
  cluster with its own NATS, Envoy Gateway and reserved IPv4. Control renders
  every tenant's Helm values in code. Per-tenant TCP listeners plus a TCPRoute
  are an existing pattern: the NATS leafnode on 7422.

## Goals / Non-Goals

**Goals**

- Cover every Cloud API gateway and aircraft:
  - Phase 1: Docks 1-4 and the O4 Ground Station.
  - Phase 2: Pilot 2 controllers.
- For those, deliver inventory, telemetry, HMS events, live video (viewers,
  NVR, search, Vantage), media and logs.
- Give every other DJI product the best available path, and name each one
  explicitly.
- Work the same self-hosted and on serviceradar.cloud.
- Keep every existing invariant:
  - telemetry goes through JetStream first
  - CNPG-backed credentials
  - no stored stream addresses
  - single deployment, no multitenancy
  - product enables are not Helm-only

**Non-Goals (follow-up changes)**

- Flight-affecting control: flight tasks, waylines, DRC, remote debug, cover
  and charge commands, OTA, custom flight areas, FlySafe unlock, emergency
  stop. These need their own RBAC, confirmation, audit and safety review
  (proposed `add-dji-fleet-operations`).
- Edge placement of the gateway as an agent add-on (`add-dji-edge-gateway-addon`).
- Edge SDK v1 boxes.
- FlightHub 2 OpenAPI.
- Passive Remote ID.
- GB28181 and Agora streaming.
- Native H.265 through recording, the media worker and Vantage
  (`add-hevc-media-pipeline`).
- DJI Cloud API 2. It is a closed, CodeMeter-licensed JNI SDK on k3s that must
  answer requests itself, so it cannot sit behind our gateway.

## Decisions

### D1. A native Rust gateway, not a Wasm plugin

The DJI peer runs as a long-lived native service, `serviceradar-dji-gateway`
(`rust/dji-gateway`), deployed by the chart as its own workload.

**Why not a plugin.** The protocol needs an always-on endpoint that devices
dial and that answers requests within the device's timeout. Wasm plugins
cannot listen and do not outlive a run.

**Why Rust.**

- It sits with the other inbound-facing collectors (`rust/otel` RUM ingress,
  `rust/trapd`, `rust/flow-collector`).
- The add-on SDK is Rust (`rust/addon-sdk`), so the same crate can later build
  the edge add-on.
- The one DJI-specific library worth reusing, `dji-log-parser`, is Rust.

No Go or Rust DJI Cloud API library exists. DJI's Java demo is MIT-licensed
but officially abandoned and marked "do not use in production". The wire
protocol is JSON, so neither language has a library advantage.

**What the gateway does.**

- Owns the DJI state machine:
  - request replies
  - topology acknowledgement
  - binding
  - `services` calls with `tid`/`bid` correlation and timeouts
  - property-set calls
  - the HMS full-set diff
  - the S3 intake
- Publishes normalized records to JetStream:
  - `serviceradar.device_discovery.v1` snapshots per gateway topology
  - `serviceradar.metric.v1` metrics
  - OCSF events
  - spatial observations
  - media and log catalog records
- Exposes a small internal gRPC API (mTLS, SPIFFE identity) that Core calls:
  - `StartLivePush`, `StopLivePush`, `SetLiveQuality`, `ChangeLens`
  - `ListLogs`, `PullLogs`
  - `GetCapabilities`

**What the gateway does not do.** It never writes CNPG or StarRocks directly.

**Where Go fits.** Go/TinyGo Wasm remains the right tool for the FlightHub 2
OpenAPI follow-up, which is a pull integration (Starlink pattern).

### D2. Device-facing MQTT: NATS MQTT listener, gated by a protocol spike

**Preferred design.** Enable the NATS server's built-in `mqtt {}` listener. It
implements MQTT 3.1.1 with QoS 0/1/2 and needs JetStream.

- The listener uses its own TLS block. It presents a publicly trusted server
  certificate and does not request client certificates, because DJI devices
  authenticate with username and password.
- It lands sessions in a dedicated `DJI` account, so MQTT clients can never
  address platform subjects.
- The `DJI` account exports only the DJI topic space, which NATS maps to
  `thing.product.*.>` and `sys.product.*.>`. The gateway's account imports it.
- Per-gateway authorization comes through the auth callout. A new
  password-grant path issues a user JWT bound to the enrollment's gateway
  serial `<gw>`:
  - publish on its own gateway topics:
    `thing.product.<gw>.{osd,state,events,requests,services_reply,property.set_reply,drc.up}`
    and `sys.product.<gw>.status`
  - publish `osd` and `state` for sub-devices: `thing.product.*.osd` and
    `thing.product.*.state`. DJI publishes each aircraft's and payload's
    telemetry on that sub-device's own topic, and sub-devices change while a
    gateway stays connected (pairing, an aircraft landing at another dock).
  - subscribe on its own downlink topics: `thing.product.<gw>.{services,property.set,drc.down,requests_reply,events_reply}`
    and `sys.product.<gw>.status_reply`
- **The gateway service enforces sub-device membership.** It accepts a
  sub-device `osd` or `state` message only when that serial is in the topology
  most recently acknowledged for the envelope's `gateway`. Anything else is
  dropped and recorded. Permissions are not re-issued on topology change.
  - **Residual risk.** An authenticated, enrolled gateway could forge `osd` or
    `state` for a sub-device currently under another gateway. That spoofs
    telemetry only, never control, because every downlink is gateway-scoped.
  - The gateway-hosted broker fallback (below) knows the publishing connection
    and can bind sub-device topics to it exactly.
- MQTT session and retained-message streams count against the JetStream
  storage budget (`jetstream-storage-budget`).

**Benefits.** No second broker to operate. JetStream durability and the
existing hosted NATS topology are reused.

**Gate (spike S1).** DJI documents "MQTT 5.0", but never states the CONNECT
protocol level, QoS, retain or Will flags that the devices actually send.
NATS rejects an MQTT 5 CONNECT. S1 captures CONNECT and SUBSCRIBE from:

- a Dock 2 or Dock 3
- an O4 Ground Station, if available
- Pilot 2 on RC Plus 2

**If any target refuses 3.1.1,** the gateway instead hosts an MQTT 5 broker in
process, bridged into JetStream with the same subject mapping and the same
per-gateway grants. The candidate is `rumqttd`, with its v5 completeness to be
evaluated in S1. Every other part of this design is identical in both
outcomes. Only the listener owner changes.

**DRC.** `drc_mode_enter` hands the device a broker address and expiring
credentials. DRC is out of scope here, but the same listener and callout path
must be able to mint those credentials later.

**WebSocket MQTT.** Pilot's `thing` module accepts `tcp://` or `ws://`.
Phase 2 uses `tcp://` (TLS) unless S1 shows Pilot needs `ws(s)://`. NATS
supports MQTT over WebSocket only through its `websocket {}` listener, and
that is verified in S1.

### D3. Credentials: three kinds, three homes

1. **DJI app credentials** (App ID, App Key, App License) and the **Open API
   key** for flight-record keychains.
   - They are credentials ServiceRadar uses toward DJI devices and DJI's
     cloud. Per the hard rule, they live in `platform.network_credential_secrets`
     as integration credentials (`provider: dji_cloud_api`,
     `dji_open_api`), managed in the credentials settings area.
   - The gateway receives them through a broker grant at start or refresh, and
     never through Helm values or env.
   - Each installation registers its own DJI app (free). Whether carverauto
     operates one app for all hosted tenants is an open question.
2. **Device enrollment credentials** (the MQTT username and password an
   operator types into a dock through Pilot or the DJI Industrial App).
   - These are credentials devices present *to* ServiceRadar. They are
     inbound, like edge onboarding tokens, not credentials used to reach a
     device.
   - They are minted by the platform and shown once. Only an Argon2id hash is
     stored, in `platform.dji_gateway_enrollments`, together with an optional
     expiry and label.
   - The first gateway serial that authenticates with an enrollment binds it
     (trust on first use). Other serials are refused unless the operator marks
     the enrollment multi-gateway.
   - Revoking an enrollment kicks the session through the callout's existing
     KICK path.
3. **Stream ingest keys.**
   - **Push-orchestrated sessions (D7).** Core mints a session-scoped token,
     embeds it in the URL sent with `live_start_push`, and stores only its
     hash on the `RelaySession`. The token can attach only to its own session,
     never while that session has an active publisher, and it expires when
     the session ends. Reconnect behaviour is in D7. Nothing long-lived exists
     to store.
   - **Source-initiated keys** (operator-pasted into Pilot manual mode, DJI
     Fly, or an encoder). These are also inbound secrets. They are shown once,
     stored hashed on the `Camera.Source`'s ingest binding, and rotatable.
   - Neither key is a stream address. Following
     `resolve-camera-stream-sources-at-edge`, the full URL is never stored at
     rest. It is rebuilt from the published endpoint and the key at display
     time.

### D4. Identity and the inventory model

- **Device rows.** Every DJI gateway, aircraft, payload, relay and dock-as-sub-device
  is a `Device`.
  - Identity is a scoped `integration_id` of the form `dji:v1:<device_sn>`
    (DIRE "Provider-Neutral Integration Identity Evidence").
  - `HardwareSerial` gains a `dji` vendor namespace.
  - An aircraft keeps one identity whichever gateway reports it, because
    aircraft move between docks and controllers.
- **IP addresses.** Gateway IPs and SIM identifiers (`dongle_infos`) are
  attributes, never identity (DIRE "Address Is Evidence, Not Identity").
- **Device type.** OCSF has no drone `type_id`. DJI hardware uses `type_id` 99
  (Other); docks and ground stations use 7 (IoT). The DJI role lives in
  `platform.dji_devices.kind` (`aircraft`, `dock`, `ground_station`, `rc`,
  `payload`, `relay`, `power`), and the UI derives icon and label from it. No
  OCSF extension is proposed.
- **`platform.dji_devices`.** A sibling table keyed by `device_uid`, holding
  current state only: `sn`, `kind`, `domain`, `model_key`, `model_name`,
  `gateway_device_uid`, `firmware_version`, `binding_state`, `online`,
  `mode_code`, `last_topology_at`, `last_osd_at`, and a bounded `capabilities`
  map (`live_capacity`). It follows the `platform.camera_sources` precedent.
  History lives in telemetry, never here.
- **Relationships.** A sub-device's relationship to its current gateway uses
  `management_device_id` (spec `device-inventory` "Management Device
  Relationship"). This continues until plugin- or component-emitted topology
  links exist.
- **Topology snapshots.** Each `update_topo` message is a complete snapshot
  for that gateway. A sub-device absent from a gateway's report goes offline
  only if that gateway is its current gateway. A late or stale report from a
  gateway the aircraft has already left cannot mark it offline. Sub-devices
  are never deleted.
- **Cameras.** Each payload and dock camera becomes a `Camera.Source`:
  - `vendor: "dji"`
  - `vendor_camera_id: "<sn>/<type-subtype-gimbalindex>"`
  - `device_uid` set to the aircraft or dock
  - `ingest_mode: push`
  - one `StreamProfile` per `video_type` (`normal`, `wide`, `zoom`, `ir`),
    taken from `live_capacity`

  This is what makes viewers, NVR policies, semantic search, VLM captions and
  Vantage work without new code, because their scope is `camera_source_id`.
- **Single deployment.** DJI "workspace" and "organization" map to the one
  deployment. The gateway answers `airport_organization_get` and
  `airport_organization_bind` with a single deployment organization. The
  binding code is the enrollment's code. No multitenancy is introduced.

### D5. Telemetry and positions

- **OSD and state properties.** The gateway converts them to
  `serviceradar.metric.v1` records on JetStream, which EventWriter persists:
  StarRocks when enabled, otherwise CNPG, never both.
  - Coverage includes:
    - battery capacity and remaining flight time
    - per-pack cycles and temperature
    - link quality and rates
    - storage
    - dock temperature, humidity, wind and rainfall
    - working voltage and current
    - mode codes
    - lifetime counters (`total_flight_time`, `total_flight_sorties`)
  - A bounded metric catalog, documented in the gateway, names each mapping.
- **Positions.** Latitude, longitude, height, heading and speed are emitted as
  atomic spatial observations under `add-spatial-observation-ingestion`. The
  stable object identity is `dji:v1:<sn>`.
  - **Interim, until #4911 and #4912 land:**
    - position is also emitted as gauges (the Starlink precedent);
    - current position is projected onto `platform.dji_devices`, so maps work
      in phase 1.
  - This change does not invent a parallel position store.
- **Rate.**
  - DJI documents OSD at 0.5 Hz. S1 measures the real rate.
  - The gateway forwards at most 1 Hz per device and never interpolates.
  - DRC can raise OSD to 30 Hz, but it requires flight-control authority and
    is out of scope.

### D6. HMS and events

- **Each HMS report is the device's complete alarm set.** The gateway diffs it
  against the previous set per `(gateway_sn, device_sn, code,
  component_index, sensor_index)`, and emits OCSF raise and clear events with a
  declared signal schema and condition key. These follow the Starlink alert
  precedent, so the existing debounce and alert rules apply.
- **Alarm text** comes from DJI's `hms.json` catalog.
  - A vendored snapshot ships with the product.
  - Core may refresh it through `ServiceRadar.HTTP.EgressClient`.
  - Air-gapped installations use the snapshot.
- **Other device events** become OCSF events, including:
  - `airsense_warning`
  - `file_upload_callback`
  - `fileupload_progress`
  - topology changes
  - binding results
- **Default alert rules** ship disabled.

### D7. Push video ingest: two new relay origins on one Membrane seam

**Ingest listeners in core-elx.**

- **RTMP listener (phase 1).** `Membrane.RTMPServer` on 1935 behind a Gateway
  API TCP listener.
  - Its pipeline demuxes FLV, converts AVCC to Annex-B, rescales millisecond
    timestamps to the 90 kHz clock, and emits the exact `{:media_chunk, ...}`
    shape that `ChunkSource` already consumes.
  - DJI documents no RTMPS. Plain RTMP carries the token in the clear, so
    push-orchestrated tokens are session-scoped and cannot attach while a
    publisher is active, to limit replay.
  - Source-initiated keys over plain RTMP are an accepted, documented risk,
    and RTMPS is supported for encoders that offer it.
- **WHIP listener (phase 4).** The `membrane_webrtc_plugin` WHIP server.
  - DJI's WHIP publisher sends no bearer auth and does no STUN/TURN. The WHIP
    URL therefore carries the session token, and the server must be reachable
    on UDP.
  - On hosted tenants that requires the same UDP exposure as TURN. Hosted WHIP
    is gated on it.
  - WHIP is the only non-Agora path that carries Dock 3/4 onboard AI results
    (SEI type 0xF5). An SEI parser turns them into camera observations.

**Relay origins.** `RelaySession` gains an `origin` attribute: `agent_pull`
(today), `push_orchestrated` or `source_initiated`.

- **`push_orchestrated`.**
  1. `RelaySessionManager.request_open` authorizes and reserves the session as
     today.
  2. Instead of `camera.open_relay` to an agent, it mints the ingest token and
     calls the gateway's `StartLivePush`. The gateway picks `url_type`
     (WHIP > RTMP) from the device's `live_capacity` and the installation's
     enabled ingests, and sends `live_start_push`.
  3. The device connects. The ingest validates the token against the reserved
     session and activates it.
  4. **Publisher loss (common on cellular).** The session stays reserved for a
     publisher-loss grace window, and the same token may re-attach, which is
     what the device's RTMP client retry does.
     - After the grace window, if any viewer, recorder or analysis lease
       remains, Core mints a new token and re-issues `StartLivePush`.
     - Otherwise it tears the session down.
     - Recordings show a bounded gap rather than ending.
  5. Viewer-idle teardown calls `StopLivePush`.
  6. Recording policies can hold the push open with the existing recorder
     lease.
- **`source_initiated`.**
  - A device or encoder connects with a long-lived key. The ingest resolves
    the key to its `Camera.Source` and opens or activates a session itself.
  - The session ends when the publisher disconnects.
  - Viewers attach to an active session. With no publisher, the source shows
    `offline`, not an error.
  - This covers Pilot manual livestream, DJI Fly RTMP where offered, and any
    RTMP encoder.
- **Agent pull still has a role.** `agent_pull` sessions remain valid for DJI
  sources where an agent can reach an RC-hosted RTSP server on the same LAN.
  That combination is deprioritized.

**Codecs.**

- **H.264.** Passes through.
- **Frame reordering.** If the stream reorders frames (B-frames), the
  `StreamProfile` is marked not recordable, and the UI says so. Viewers still
  work. The ingest does not silently drop frames.
- **H.265 over enhanced RTMP.**
  - `Membrane.FLV.Demuxer` gains an HEVC path. It emits `%Membrane.H265{}`
    stream format from the `hvc1` sequence start the parser already decodes.
    We carry it as a patch in `third_party/hex_vendored` and contribute it
    upstream to `membrane_flv_plugin`.
  - Until `add-hevc-media-pipeline` lands, the ingest transcodes H.265 to
    H.264 using the already-present `membrane_h265_ffmpeg_plugin` and
    `membrane_h264_ffmpeg_plugin`. The transcode is bounded per session and
    counted in relay metrics.
  - DJI documents H.264 Annex-B for Dock 3. S3 confirms the RTMP codec per
    model.
- **Stream protocol preference per device:** WHIP, then RTMP, then RTSP pull
  (LAN only). Agora and GB28181 are not implemented.

**Clock.** Sessions use `time_basis: received`. A later change can map device
timestamps (Dock 4 `sync_live_view_timestamp`) to `camera_reported`. Drone pose
is correlated with frames by time through spatial observations and
`camera_source_id`, because the Vantage frame envelope carries no geo fields.

### D8. Media and log intake

- **The intake endpoint.** DJI devices upload with STS-style credentials:
  `{bucket, region, endpoint, provider: ali|aws|minio, object_key_prefix,
  credentials{...}}`.
  - Rather than require an STS-capable store, the gateway serves an
    S3-compatible intake endpoint. The candidate is the Apache-2.0 `s3s` crate
    (SigV4 server). It accepts only credentials the gateway minted: short
    expiry, one prefix, PutObject and multipart only.
  - The endpoint streams objects into the installation's configured object
    storage (the NVR archive S3 target or local storage).
  - Pilot and docks are told `provider: minio` with a path-style endpoint.
    Spike S4 verifies that devices accept it.
- **Media catalog.** `file_upload_callback` metadata becomes rows in
  `platform.dji_media_files` (current catalog, CNPG):
  - `object_key`, `flight_id`, drone and payload model keys
  - shoot position and altitudes, gimbal yaw, create time

  Feeding uploaded video into semantic search is a follow-up.
- **Device logs.**
  - `fileupload_list` and `fileupload_start`, for dock and aircraft modules,
    run on operator request through Core and the gateway. The uploads land in
    the same intake.
  - The format is undocumented and DJI-support oriented, so logs are stored
    opaque and offered for download.
- **Flight records.** DJI flight records are parsed with `dji-log-parser`
  (MIT) using DJI's keychain API and the Open API key (D3). Sources:
  - Dock 4 media `module` 2
  - manual upload
  - consumer import (D13)

  Details:
  - Keychains are cached, so re-parsing works offline.
  - Parsed tracks become spatial observations with `source: flight_record`.
  - Flight summaries become OCSF events.
  - Formats `dji-log-parser` cannot yet read (M4TD encrypted-from-byte-0, v14
    waypoint crashes) are stored unparsed and reported. Fixes go upstream.
- **No reverse engineering.** DJI's flight-record API license (section 3.3)
  and SDK EULA (section 3.2(b)) forbid reverse engineering, and the
  sanctioned keychain path covers flight records.
  - `PlogDecoder.jar` decodes only Pilot 2 *diagnostic* logs, encrypted to a
    public key we supply. It ships without license terms.
  - Pilot diagnostic log pull is therefore out of scope until the user decides
    whether it is worth pursuing (open question).

### D9. DJI Pilot 2 access (phase 2)

- **H5 page (web-ng).** web-ng serves the H5 page at `/dji/pilot`, with a
  minimal, Pilot-WebView-safe layout. The page:
  1. calls `platformVerifyLicense` with the app credentials from a broker
     grant;
  2. authenticates the operator as a ServiceRadar user, with the RBAC
     permission `drones.pilot.connect`;
  3. receives a short-lived signed Pilot session token and per-session MQTT
     credentials minted through the D2 callout path;
  4. loads the `thing`, `api`, `ws`, `liveshare`, `media` and `tsa` modules
     and sets the workspace to the deployment workspace.
- **Pilot HTTPS and WebSocket (gateway).** The gateway serves the module APIs
  Pilot calls under the deployment hostname:
  - `storage` (`sts`)
  - `media` (`fast-upload`, `tiny-fingerprints`, `upload-callback`)
  - `manage` (topologies)
  - minimal `map`
  - the WebSocket push

  All are routed by Gateway API `HTTPRoute` path prefixes. Whether Pilot
  accepts a base URL with a path prefix is verified in S1.
- **Wayline endpoints** are part of `add-dji-fleet-operations`.

### D10. Enablement, chart and hosted tenants

- **Product setting.** `DjiFleetSettings` is a CNPG-backed runtime settings
  resource managed in web-ng. Its fields:
  - `enabled`
  - enabled ingests (`rtmp`, `whip`)
  - OSD forward rate cap
  - media intake on/off
  - log retention

  It defaults to disabled. It is the user-facing switch and is never a Helm
  value.
- **Chart plumbing.** The chart renders:
  - the `dji-gateway` workload
  - the NATS `mqtt {}` block and `DJI` account
  - Gateway API TCP listeners and TCPRoutes for MQTT (8883 TLS) and RTMP (1935)
  - the HTTPRoutes for the Pilot APIs

  These render when the installation's chart values provide them, the same
  way leafnode and collector listeners do today. Self-hosted installations set
  those values once. The workloads idle harmlessly while the product setting
  is off.
- **Public endpoints.** The hosted runtime contract and the self-hosted
  equivalent publish the MQTT and RTMP host and port facts. The settings page
  shows exactly what an operator types into a dock.
- **TLS trust (spike S2).** DJI states that Pilot 2, the docks and the O4
  "support certificates issued by GoDaddy", which hints at a restricted trust
  store. S2 verifies whether a Let's Encrypt chain (what cert-manager issues
  for hosted tenants) is accepted on MQTT 8883.
  - If it is not, hosted MQTTS needs a certificate from an accepted CA for the
    tenant's DJI hostname. That is a procurement decision for the user, so it
    is an open question.
  - Plain MQTT on 1883 is never enabled by default.
- **Hosted tenants (companion change in `carverauto/serviceradar-control`).**
  It mirrors the `nats_leaf` precedent (`add-tenant-edge-connectivity-launch-validation`):
  - a `dji_fleet_enabled` plan entitlement, projected as env and
    `hostedRuntime.entitlements`
  - a minimum chart version in `TenantChartCapabilities`
  - MQTT, RTMP and WHIP facts in `HostedRuntimeContract.public_endpoint_contract`
  - an `enforce_hosted_dji_values` step that renders the chart values above
  - `mqtt` and `rtmp` exposure kinds in `NetworkExposurePlan`, DNS
    (`sync_dns`) and the `TenantTlsPlan` SANs
  - a per-exposure public firewall opt-in. Docks on LTE have unpredictable
    source addresses, so device authentication carries the security.
  - A signal path so that turning the product setting on, when entitled,
    triggers a guarded chart re-render (`HelmSingleWriter`). Control has no
    product-to-control signal today. The companion change chooses between
    polling the product runtime endpoint and a product-initiated callback.

  Hosted live viewing also needs TURN, which control does not render for
  tenants today. That gap is tracked in the companion change.

### D11. SRQL and UI

- **SRQL.** `in:drones` reads `platform.dji_devices` joined to `ocsf_devices`
  (current state, CNPG) and follows the `in:websites` entity precedent.
  Telemetry stays in `in:timeseries_metrics` and events in `in:events`.
  Media gets `in:drone_media`, a catalog over `platform.dji_media_files`.
- **Device detail.** Devices with a `dji_devices` row get a "Drone" tab
  showing:
  - kind, model and firmware
  - gateway and paired aircraft
  - battery packs
  - link and SIM state
  - dock environment
  - current HMS alarms
  - live view buttons per camera
  - log pull
- **Dashboard.** A first-party dashboard package, `drone-fleet`, in
  `elixir/web-ng/priv/dashboard-packages/`, built with the dashboard SDK. It
  contains:
  - a geographic map: aircraft icons rotated by heading, dock range rings,
    tracks as `path` layers, flight areas as `polygon` layers once operations
    exist
  - a fleet table
  - a dock environment panel
  - an HMS feed (`events.subscribe`)
  - a `CameraGrid` live view (`camera.stream.view`)

  It adopts `add-shared-spatial-resources` providers when they land.

### D12. Testing without leaking real data

- **Simulator.** `rust/dji-gateway` ships an in-repo DJI Cloud API protocol
  simulator. It connects as a dock, an O4 and a Pilot gateway with
  **invented** serials, model keys from the public DJI table, and coordinates
  of a public reference location. It drives:
  - topology
  - OSD and state
  - HMS sets
  - binding
  - media callbacks
  - an RTMP push from a synthetic clip
- **Reuse of the simulator.**
  - The `add-showcase-demo-portfolio` `drone-fleet` source should drive this
    simulator rather than emit plugin metrics directly. The demo then
    exercises the real path.
  - Community simulators (`YuYongJu/dji-cloud-simulator`, MIT) may inform
    message shapes. Their captured data is not copied.
- **Hardware spikes S1-S4.** They run against lab hardware. Their captures
  answer yes/no and shape questions only. No captured serial, payload,
  coordinate, SIM identifier or firmware build enters the repository; fixtures
  are regenerated from the simulator.

### D13. Product line coverage matrix

| Family | Path | What ServiceRadar gets | Phase |
|---|---|---|---|
| Dock 1 / 2 / 3 + M30, M3D, M4D series | Cloud API via gateway | inventory, telemetry, HMS, live video (RTMP, later WHIP plus onboard AI), media, logs, flight records | 1 (media/logs 3, WHIP 4) |
| O4 Ground Station + Dock 4 + M5TD | Cloud API via gateway (O4 is the gateway; Dock 4 is a sub-device) | same, plus airspace RID/ADS-B events from an attached ESDK v2 sensor | 1 |
| RC Plus / RC Plus 2 / RC Pro Enterprise / Smart Controller Enterprise + Pilot 2 (M30, M300, M350, M4E/M4T, M400, M3E/M3T/M3TA; H20/H30 payloads) | Cloud API via Pilot 2 H5 + gateway | inventory, telemetry, HMS, live video, media | 2 |
| Any DJI product with an RTMP livestream option (Pilot manual mode; DJI Fly where offered) | source-initiated RTMP | live video, NVR, search; no telemetry | 1 |
| Any DJI aircraft (consumer Mini/Air/Mavic/Avata/Neo/Flip, Matrice, Mavic 3E) | flight record import (`dji-log-parser`) | post-flight device identity, track history, flight summaries | 3 |
| FlightHub 2 customers | FlightHub 2 OpenAPI (Go Wasm plugin, pull) | devices, missions, flight records, media | follow-up |
| Docks 1-3 with an ESDK v1 edge box | Edge SDK v1 (C++ shim as agent add-on) | LAN H.264 live view and media without the cloud round trip | follow-up |
| Any drone in RF range, including non-DJI | passive Remote ID (ASTM F3411) receiver add-on | serial/UAS ID, position, operator position | follow-up |
| Mini 3 / Mini 3 Pro / Mini 4 Pro | custom MSDK v5 app | app-level telemetry and video | not planned |
| Agras, FlyCart 30/100 | no public API found (DeliveryHub is public-cloud only) | none | not possible today |
| M3M, P1/L1/L2, third-party payloads | not in Cloud API support list | aircraft-level data only, where the aircraft is supported | n/a |

## Risks / Trade-offs

- **The MQTT protocol level is unknown.** The S1 gate holds the broker
  decision, and the fallback is fully specified.
- **The device trust store may exclude Let's Encrypt.** S2 tests this before
  the hosted rollout. Procurement is the fallback.
- **Plain-RTMP token exposure.** Session-scoped tokens that cannot attach
  while a publisher is active, and the
  WHIP preference mitigate it, and the residual risk is documented for
  source-initiated keys.
- **H.265 transcode cost** is bounded per session, counted, and removed by
  `add-hevc-media-pipeline`.
- **An enrollment credential leak** is limited by first-use serial binding,
  per-gateway subject grants and revocation KICK.
- **License verification may need internet access** (unverified). Air-gapped
  sites may not be supported, and S1 records the result.
- **The single `CameraMediaSessionTracker` GenServer** funnels every chunk. A
  drone fleet adds sessions. The design does not fix this, but the relay
  scaling work (`add-scalable-camera-recording-plane`) must account for push
  sources.

## Migration Plan

This is a new, opt-in feature, so there is no data migration. The rollout:

1. Release the chart with the listeners off.
2. Turn on per installation.
3. On hosted tenants, an entitlement, chart gate and re-render through the
   control companion change.

Rollback means turning the setting off and removing the listener values. DJI
devices then fail to connect and keep their own config.

## Open Questions

1. **Lab hardware.** Which DJI hardware is available for spikes S1-S4? At
   minimum a Dock 2 or 3, and an RC Plus 2 with an M4-series aircraft.
2. **Hosted DJI app.** Does carverauto register one DJI Cloud API app for all
   hosted tenants, or does each tenant bring its own?
3. **Hosted TLS fallback.** If S2 shows Let's Encrypt is not trusted, is
   buying a certificate from an accepted CA per hosted DJI hostname
   acceptable?
4. **Pilot diagnostic logs.** Pursue them (`PlogDecoder.jar`) at all, given
   their limited value and the unclear license? Reverse engineering is not
   proposed.
5. **Air-gapped dock license verification.** Is air-gapped operation a
   requirement? It depends on whether license verification works offline,
   which S1 tests.
