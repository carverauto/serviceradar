# Change: Add DJI drone fleet integration (Cloud API gateway, push video ingest, fleet inventory)

## Why

Operators who fly DJI enterprise drones and docks have no way to see that fleet
in ServiceRadar. Docks, remote controllers, aircraft and payload cameras do not
appear in inventory. Battery, link, weather and position telemetry is not
trended. DJI health (HMS) alarms never become events. Live video cannot be
watched next to the rest of the estate, recorded by the NVR, or searched and
analysed by the camera pipeline and, later, Vantage.

DJI's integration surface is the opposite of the integrations ServiceRadar has
today. UniFi Protect, Axis and Starlink are *pulled*: an agent or plugin calls
out to a controller. In the DJI Cloud API, the field gateway (a DJI Dock, an
O4 Ground Station, or a remote controller running DJI Pilot 2) connects *in* to
an MQTT broker and HTTPS/WebSocket API that the platform hosts. The platform
must answer the device's requests (license configuration, organization binding,
storage credentials, topology acknowledgements). The device then *pushes* live
video to a server URL the platform hands it, over RTMP, WebRTC/WHIP or
GB28181. No current ServiceRadar component accepts device-initiated
connections of this kind:

- Wasm plugins are outbound-only and their runs are bounded.
- Camera relay sessions can only start from Core.
- The relay pulls RTSP.
- No MQTT listener is configured anywhere in the product.

The user wants as much of the DJI product line covered as is technically
possible, with the Dock family first. It must also be available to hosted
serviceradar.cloud tenants, not only self-hosted installations.

## What Changes

- **New native component `serviceradar-dji-gateway`** (Rust, `rust/dji-gateway`).
  It implements the platform side of the DJI Cloud API: the request/reply
  state machine, topology, organization binding, license configuration replies,
  service invocation, the HMS/event intake, and an S3-compatible media and log
  intake endpoint. It emits only existing product contracts over NATS
  JetStream. It is not a Wasm plugin, because the protocol requires an
  always-on, inbound-facing endpoint (design D1).
- **Device-facing MQTT broker.** The NATS server's built-in MQTT listener is
  enabled in an isolated `DJI` account. Per-gateway credentials and per-gateway
  subject grants are issued through the existing NATS auth callout. Before that
  choice is final, a hardware spike captures the MQTT protocol level that docks
  and Pilot 2 actually send. If any target speaks only MQTT 5, the gateway
  hosts an MQTT 5 broker instead (design D2).
- **Fleet inventory.**
  - Docks, O4 Ground Stations, remote controllers, aircraft and payloads become
    `Device` rows. DIRE keys them by DJI serial number (scoped `integration_id`
    plus a `dji` hardware-serial namespace), not by IP address.
  - A `platform.dji_devices` sibling table holds DJI current state: model key,
    domain, gateway, binding state and online state.
  - The aircraft-to-gateway relationship uses `management_device_id`.
  - Payload and dock cameras become `Camera.Source` / `StreamProfile` rows, so
    the existing viewers, NVR, semantic search and Vantage apply unchanged.
- **Telemetry and events.**
  - OSD and state properties become `serviceradar.metric.v1` records on
    JetStream, persisted by EventWriter.
  - Positions follow the spatial observation contract
    (`add-spatial-observation-ingestion`).
  - HMS alarm sets become OCSF events with raise/clear transitions.
- **Push video ingest in the Membrane relay.**
  - core-elx gains an RTMP ingest listener (`Membrane.RTMPServer`, already
    compiled in through the vendored boombox) and, in a later phase, a WHIP
    ingest (`membrane_webrtc_plugin` WHIP server). Both feed the existing relay
    `Pipeline` through its chunk seam.
  - Two new relay origins:
    - **push-orchestrated**: Core reserves the session, mints a session-scoped
      ingest token, and asks the gateway to send `live_start_push`.
    - **source-initiated**: a device or encoder pushes with a long-lived
      stream key, for Pilot manual mode and non-Cloud-API products.
  - The FLV demuxer gains an H.265 (enhanced RTMP `hvc1`) path, to be
    contributed upstream. Until the pipeline handles H.265 natively, H.265 is
    transcoded to H.264 at ingest. Stream protocol is chosen per device from
    its reported capability, and WHIP is preferred where available.
- **Media and logs.**
  - Docks and Pilot upload photos, videos, PPK files, flight records and device
    logs into ServiceRadar object storage through gateway-minted, short-lived,
    prefix-scoped credentials.
  - Flight records are parsed with the MIT-licensed `dji-log-parser` crate
    using DJI's sanctioned keychain API. Nothing is reverse engineered.
- **DJI Pilot 2 access (phase 2).**
  - web-ng serves the Pilot 2 H5 login page, verifies the DJI license, and
    mints short-lived Pilot session and MQTT credentials.
  - The gateway serves the HTTPS module endpoints and WebSocket push that Pilot
    requires.
- **Product line coverage beyond the Cloud API.**
  - Any DJI product or encoder that can push RTMP (Pilot manual mode, DJI Fly
    live streaming where the model offers it) is a source-initiated video
    source.
  - Flight records from any DJI aircraft can be imported for post-flight
    inventory and track history.
  - Further paths are named follow-ups: FlightHub 2 OpenAPI, Edge SDK v1 edge
    boxes, and passive Remote ID (design D13).
- **Enablement.**
  - A product runtime setting, stored in CNPG and managed in web-ng, turns the
    integration on.
  - The chart renders the gateway, the NATS `mqtt {}` listener, and Gateway API
    TCP listeners for MQTT(S) and RTMP when the installation provides them.
  - The hosted runtime contract publishes the endpoints that operators type
    into docks.
  - A companion change in `carverauto/serviceradar-control` adds the hosted
    entitlement, chart gate, endpoint contract, DNS/SAN, and a public firewall
    opt-in for these listeners (design D10).
- **First-party `drone-fleet` dashboard package** containing:
  - fleet map with icons, tracks and dock range
  - fleet table
  - dock environment
  - HMS feed
  - live camera grid
- **New SRQL entity `in:drones`** over current fleet state.
- **Out of scope here, planned as follow-up changes:**
  - flight control (flight tasks, waylines, DRC, remote debug, OTA, custom
    flight areas, emergency stop)
  - edge placement of the gateway as an agent add-on
  - ESDK edge boxes
  - FlightHub 2 OpenAPI
  - passive Remote ID
  - GB28181 and Agora streaming
  - native H.265 through the recording and analysis pipeline

## Impact

- **New specs:** `dji-cloud-gateway`, `drone-fleet-inventory`.
- **Modified specs:** `camera-streaming` (ADDED requirements only: push-ingest
  relay origins and codec normalization).
- **Affected code:**
  - **New code:** `rust/dji-gateway/`.
  - **core-elx:**
    - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/`
      (ingest listeners, push relay origin)
    - vendored or patched `membrane_flv_plugin` demuxer
  - **serviceradar_core:**
    - `elixir/serviceradar_core/lib/serviceradar/camera/`: relay session
      origin, `Source` ingest mode
    - `.../inventory/`: DJI identity, sibling resource
    - `.../nats/managed_certificate_authorization.ex`, or a sibling callout
      for device passwords
    - EventWriter consumers for DJI subjects
  - **SRQL:** `rust/srql` (`in:drones`).
  - **web-ng:**
    - settings
    - Pilot H5 page
    - first-party dashboard package
    - device detail tab
  - **Chart:**
    - `helm/serviceradar/templates/nats.yaml` (`mqtt {}` block, `DJI` account)
    - `gateway-api.yaml` (MQTT/RTMP TCP listeners and routes)
    - a new `dji-gateway` workload
  - **Control companion change:** `carverauto/serviceradar-control`.
- **Dependencies and coordination:**
  - `add-spatial-observation-ingestion` (#4911) and
    `add-spatial-history-projection` (#4912) for tracks.
  - `add-shared-spatial-resources` (#4910) for maps.
  - `add-vms-storage-playback-engine` and `add-nvr-retention-and-timeline-playback`
    for recording.
  - `resolve-camera-stream-sources-at-edge`: stream addresses are never stored.
  - `add-showcase-demo-portfolio`: its simulated `drone-fleet` source should
    speak the DJI Cloud API to this gateway.
  - Hosted live viewing also depends on TURN reaching hosted tenants, which is
    a known control gap.
- **External prerequisites:**
  - A DJI developer account and a Cloud API app (App ID, App Key, App License;
    free).
  - An "Open API" app key for flight record decryption.
  - Lab hardware for the phase 0 spikes: at least one Dock 2 or Dock 3, and one
    RC Plus 2 with an M4-series aircraft.
- **Data hygiene:** captures from lab hardware are used only to answer the
  spike questions. Every fixture, simulator scenario and doc sample is
  invented, and no captured serial, MQTT payload or coordinate is committed
  (repository rule).
