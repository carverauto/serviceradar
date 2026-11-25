---
id: vantage
title: ServiceRadar Vantage (VMS)
sidebar_label: ServiceRadar Vantage (VMS)
description: Edge-native IP camera VMS and private on-premises visual intelligence unified with ServiceRadar inventory, network observability, RBAC, and Solution Packs.
---

# ServiceRadar Vantage (VMS)

![ServiceRadar Vantage](/img/vantage-logo-dark.png)

Conventional IP camera deployments split physical security video into a separate
appliance or cloud subscription, disconnected from switch ports, identity rules,
and operational telemetry. **ServiceRadar Vantage** brings edge-native Video
Management System (VMS) capabilities and private on-premises visual intelligence
directly into ServiceRadar. Cameras are first-class inventory assets alongside
routers, switches, and hosts, sharing unified credential management, SRQL
queries, OCSF alerting, and per-request Role-Based Access Control (RBAC).

| Surface | Route |
| --- | --- |
| Camera Fleet & Live Console | `/cameras` |
| Unified Timeline, Clips & Legal Holds | `/cameras/:camera_source_id/recordings` |
| Recording, Spool & Archive Settings | `/settings/recording` |
| Unified Credentials & Rules | `/settings/networks/credentials` |

## Overview and Open-Core Model

ServiceRadar follows an open-core model for video operations:

- **Open-Source Edge VMS (Included in ServiceRadar):** Edge-native IP camera
  discovery and onboarding, continuous local recording with outage buffering,
  S3-compatible object archiving, live WebRTC/WebSocket playback, precision
  timeline scrubbing, detection zones, legal holds, and RBAC audit trails.
- **ServiceRadar Vantage (Commercial Addon):** Private on-premises visual
  intelligence deployed alongside your ServiceRadar cluster. Vantage adds smart
  event classification, automated scene indexing, and plain-English natural
  language video search -- all running locally with **zero cloud video egress**.

Every subsystem enforces three core operational principles:

1. **Plane isolation by default.** Media capture, continuous recording, AI
   indexing, and operator playback run in isolated planes. An AI addon restart
   or workload spike never interrupts continuous recording or live viewing.
2. **100% private on-premises execution.** Visual analysis and plain-English
   search run entirely inside your own infrastructure. No video frames,
   thumbnails, or search prompts ever leave your site.
3. **Zero-trust credentials and auditability.** Camera credentials remain
   encrypted in ServiceRadar's unified credential store and are brokered to edge
   agents via scoped rules. Live viewing, historical playback, and legal holds
   are governed by separate RBAC permissions with full access auditing.

![ServiceRadar Vantage four-strata architecture: Edge Cameras, Recording and Archiving, Private Vantage AI Addon, and Control Plane](/img/vantage-architecture-strata.svg)

*Figure 1 -- High-level Vantage architecture from edge cameras and continuous recording to the private Vantage AI addon and ServiceRadar web console.*

## Camera Onboarding and Recording Policies

Cameras connect through ServiceRadar edge agents over mutually authenticated
TLS (mTLS), keeping camera VLANs isolated from the control plane:

- **Stream Profiles:** Onboard cameras via standard **RTSP/RTSPS**, **ONVIF**,
  **UniFi Protect**, or **Axis** plugins using brokered credentials configured
  in `/settings/networks/credentials`. See [UniFi Protect](./unifi-protect.md)
  and [Credential Management](./credentials.md).
- **Continuous Recording with Outage Buffering:** Local edge NVR storage writes
  crash-safe recording segments continuously so transient network outages or
  control-plane maintenance do not drop footage.
- **Local Retention and S3-Compatible Archiving:** Configure local storage
  retention policies and long-term S3-compatible object archiving in
  `/settings/recording`. Archived media is verified on readback before local
  storage capacity is reclaimed. See [Camera Recording & NVR](./camera-recording.md).
- **Live and Recorded Playback:** View low-latency live streams over WebRTC
  (with automatic WebSocket fallback when traversing restrictive NATs; see
  [WebRTC TURN Relay](./webrtc-turn-relay.md)) and scrub recorded history on
  the unified timeline at `/cameras/:camera_source_id/recordings`.
- **Network Correlation:** Every camera source links to its underlying
  ServiceRadar inventory device so PoE switch port health, link flaps, and
  recording gaps appear in one operational view.

| Capability | Operator Guarantee |
| --- | --- |
| **Crash-safe local recording** | Continuous segments are sealed durably on local storage before archiving or indexing. |
| **Readback-verified S3 archive** | Archived objects are verified before local retention policies reclaim disk space. |
| **Outage resilience** | Local recording continues uninterrupted if upstream connectivity or AI services restart. |
| **Timeline provenance** | Coverage bands clearly distinguish local, archived, pending-archive, gap, and retention-deleted spans. |

## Smart Alerts and Detection Zones

The investigation console at `/cameras/:camera_source_id/recordings` pairs live
viewing with noise-reduced event triage and precision scrubbing:

- **Detection Zones (Focus and Ignore Regions):** For fixed cameras, operators
  paint **Focus** and **Ignore** zones directly onto a camera snapshot to mask
  high-traffic roadways, swaying foliage, or neighboring property before clips
  and alerts are generated.
- **Reduced False Alerts:** Vantage suppresses repetitive alerts from stationary
  objects -- such as parked vehicles sitting in a driveway or lot -- while still
  triggering promptly when a vehicle arrives, moves, or departs.
- **Tiered Smart and Basic Event Rail:** Events are organized into **Smart**
  (`Person`, `Vehicle`, `Animal`, `Package`) and **Basic** (`Motion`,
  `Recording`) rails so high-volume background motion never buries actionable
  security events.
- **Precision Timeline, Filmstrip, and Overlays:** Scrub across `15m`, `1h`,
  `6h`, `24h`, and `7d` windows with a synchronized thumbnail filmstrip,
  `+`/`-` zoom, and frame-synchronized playback overlays during play, pause, and
  frame-stepping.

## Private Plain-English Video Search (Vantage Commercial Addon)

With the commercial **ServiceRadar Vantage** addon enabled, operators can search
hours or days of recorded footage using plain natural language -- without
manually scrubbing timelines or uploading video to a third-party cloud.

Example operator queries:

- `"person walking a dog"`
- `"delivery truck at gate"`
- `"white van backing into loading bay"`
- `"person carrying a box near side entrance"`

Operators can narrow results by **camera**, **site**, **time range**, and
**detection category**, review ranked clip thumbnails and summaries, and click
any result to **jump straight to the exact matching timestamp** on the camera
timeline.

![Private visual search workflow from operator query through the private on-premises Vantage AI engine to verified clips and direct timeline jump](/img/vantage-private-visual-search.svg)

*Figure 2 -- End-to-end private visual search: queries and video stay 100% on-premises, returning RBAC-scoped clips with one-click timeline jump.*

Because the Vantage AI engine runs strictly inside your own cluster, sensitive
facility footage, employee activity, and incident search prompts never leave
your network boundary.

## Governance, Legal Holds, and RBAC

Video access and evidence preservation are enforced consistently across the web
console, timeline playback, and APIs:

| Permission | Scope |
| --- | --- |
| `devices.cameras.view` | View camera inventory status and watch live camera streams. |
| `devices.cameras.recordings.view` | Browse recorded timelines, search clips, and play historical footage. |
| `devices.cameras.recordings.hold` | Place and release immutable legal holds on recorded intervals. |

- **Immutable Legal Holds (`RecordingHold`):** Pin matching camera time ranges
  across both local NVR storage and S3 archives. Held footage is protected from
  automated retention eviction until an authorized operator explicitly releases
  the hold.
- **Complete Access Audit Trail (`RecordingAccessAudit`):** Every historical
  playback request is recorded with operator identity, camera, and timestamp
  metadata to support compliance and chain-of-custody reviews.

See [Roles & Permissions](./rbac-and-roles.md) for configuring custom RBAC roles
and camera scopes.

## Deployment and Extensibility

### Deploying the Commercial Vantage Addon

The commercial **ServiceRadar Vantage** addon deploys alongside ServiceRadar
using Helm values, a licensed container registry pull secret, and your Vantage
license entitlement. Because it consumes sealed media through scoped,
short-lived read grants and runs in isolated cluster workloads, you can enable
or upgrade Vantage on an existing ServiceRadar deployment without reconfiguring
cameras or interrupting NVR recording.

Contact Carver Automation to obtain a commercial Vantage license and Helm addon
configuration guide.

### Building Custom Extensions with the ServiceRadar SDK

Organizations and partners can extend Vantage for vertical use cases -- such as
Automatic License Plate Recognition (ALPR), PPE compliance, safety checks, or
automated gate workflows -- and distribute them as ed25519-signed **Solution
Packs** (`pack_format_version: 1`). See [SDKs & Plugin Development](./sdks.md)
and [Solution Packs & Declarative Checks](./solution-packs.md).

![Vantage extensibility three progressive compute ramps converging into unified observations and signed Solution Packs](/img/vantage-sdk-three-ramps.svg)

*Figure 3 -- Three progressive extension ramps sharing one canonical observation contract, SRQL query entity, and signed `.srpack` distribution format.*

| Ramp | Execution Model | Best For |
| --- | --- | --- |
| **Ramp 1: Declarative Visual Pipelines** | Zero-code JSON pipeline definitions executed by the private Vantage AI addon. | Rapid prototyping, OCR/ALPR, PPE checks, and scene classification without maintaining a custom container. |
| **Ramp 2: External SDK Worker** | Out-of-process Rust or Python worker built with `serviceradar-sdk-vantage` using scoped media read grants and zero database credentials. | High-throughput or specialized custom analytics isolated across a process or network boundary. |
| **Ramp 3: WASM Action Bridge** | Sandboxed WebAssembly plugin (`serviceradar-sdk-go` / `serviceradar-sdk-rust`) consuming structured observations and OCSF events. | Deterministic watchlist matching, signed webhooks, ticket creation, and gate or relay automation. |

ServiceRadar ships an Apache-2.0 reference pack, `io.serviceradar.vantage-alpr`,
demonstrating how declarative pipelines, custom schemas, and OCSF alert rules
bundle into a single signed `.srpack` that can upgrade seamlessly from Ramp 1 to
a dedicated Ramp 2 worker without changing downstream queries or alerts.

### Querying Camera Observations with SRQL (`in:camera_observations`)

Structured observations emitted by Vantage extensions are queryable through SRQL
and correlated with your network and device inventory:

| Use Case | SRQL Query |
| --- | --- |
| Recent ALPR reads on a gate camera | `in:camera_observations pipeline:"alpr" camera:"cam-north-gate-01" time:last_24h` |
| High-confidence reads across a site | `in:camera_observations site:"site-a" signal_type:"license_plate_read" confidence:>=0.90` |
| Exact synthetic plate lookup | `in:camera_observations pipeline:"vantage-alpr" plate_text:"ABC-1234" time:last_7d` |

Example synthetic observation payload for camera
`00000000-0000-0000-0000-000000000001` (`cam-north-gate-01`, `site-a`,
`192.0.2.10`):

```json
{
  "camera_source_id": "00000000-0000-0000-0000-000000000001",
  "camera_name": "cam-north-gate-01",
  "site": "site-a",
  "pipeline_slug": "vantage-alpr",
  "signal_type": "license_plate_read",
  "observed_at": "2026-11-24T14:32:10Z",
  "confidence": 0.94,
  "attributes": {
    "plate_text": "ABC-1234",
    "vehicle_class": "van",
    "direction": "inbound"
  }
}
```

## Related Pages

- [Camera Recording & NVR](./camera-recording.md) -- NVR spool topology, S3
  archive bindings, retention watermarks, legal holds, and timeline HTTP API.
- [UniFi Protect](./unifi-protect.md) -- configuring UniFi OS credentials,
  rules, and camera stream plugins.
- [WebRTC TURN Relay](./webrtc-turn-relay.md) -- configuring TURN relay for
  low-latency live WebRTC playback across NAT boundaries.
- [Solution Packs & Declarative Checks](./solution-packs.md) -- `.srpack`
  packaging, ed25519 signing, and GitOps promotion.
- [SDKs & Plugin Development](./sdks.md) -- overview of `serviceradar-sdk-go`,
  `serviceradar-sdk-rust`, `serviceradar-sdk-dashboard`, Solution Packs, and
  `serviceradar-sdk-vantage`.
- [Credential Management](./credentials.md) -- unified credentials and brokered
  access rules.
- [Roles & Permissions](./rbac-and-roles.md) -- camera live, playback, and
  legal hold RBAC permissions.
