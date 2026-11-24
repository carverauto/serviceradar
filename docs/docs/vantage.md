---
id: vantage
title: ServiceRadar Vantage (VMS)
sidebar_label: ServiceRadar Vantage (VMS)
description: Edge-native IP camera VMS and local GPU visual intelligence unified with ServiceRadar inventory, network observability, RBAC, and Solution Packs.
---

# ServiceRadar Vantage (VMS)

<div style={{display: 'flex', alignItems: 'center', gap: '0.75rem', marginBottom: '1.25rem'}}>
  <img src="/img/vantage-logo.svg" alt="ServiceRadar Vantage brand mark" width="36" height="36" style={{flexShrink: 0}} />
  <div>
    <strong>ServiceRadar Vantage</strong> -- Edge-native IP camera VMS and local GPU visual intelligence
  </div>
</div>

Conventional IP camera deployments split physical security video into a separate
appliance or cloud subscription, disconnected from switch ports, identity rules,
and telemetry pipelines. **ServiceRadar Vantage** is an edge-native Video
Management System (VMS) and local GPU visual intelligence engine built directly
into ServiceRadar. Cameras are first-class inventory assets alongside routers,
switches, and hosts, sharing the same unified credentials, SRQL query surface,
OCSF alerting, and per-request Role-Based Access Control (RBAC).

| Surface | Route |
| --- | --- |
| Camera Fleet & Live Console | `/cameras` |
| Unified Timeline, Clips & Legal Holds | `/cameras/:camera_source_id/recordings` |
| Recording, Spool & Archive Settings | `/settings/recording` |
| Unified Credentials & Rules | `/settings/networks/credentials` |

## Design Rules

Every subsystem in Vantage enforces four architectural invariants:

1. **Plane isolation by default.** Media capture, durable fMP4 spooling, GPU
   visual indexing, and operator playback run in separate planes. A GPU worker
   restart or queue spike never interrupts continuous recording or live viewing.
2. **Zero external cloud egress.** Object detection, visual embeddings, scene
   captioning, and semantic search run on in-cluster GPU workloads. No video
   frames, thumbnails, or search prompts leave the cluster.
3. **Zero database credentials in media workers.** GPU and external ML workers
   fetch sealed blocks over an isolated `:8445` analysis endpoint using
   short-lived Fragment Read Grants and publish results exclusively to NATS
   JetStream (`media.results.>`). Only `core-elx` `EventWriter` writes to CNPG.
4. **Zero-trust credentials and auditability.** Camera credentials stay
   encrypted in `platform.network_credential_secrets` and are brokered to edge
   agents via credential rules. Live viewing (`devices.cameras.view`),
   historical playback (`devices.cameras.recordings.view`), and legal holds
   (`devices.cameras.recordings.hold`) are gated separately, with every playlist
   access recorded in `RecordingAccessAudit`.

## Architecture and Data Flow

![ServiceRadar Vantage four-strata architecture: Edge, Storage, GPU Inference, and Control Plane](/img/vantage-architecture-strata.svg)

*Figure 1 -- Four isolated strata from multi-vendor camera capture to CNPG projections and the Vantage Console.*

### Component & Model Stack

| Stratum | Component | Runtime / Model | Responsibility |
| --- | --- | --- | --- |
| **Edge** | `serviceradar-agent` + camera plugins | UniFi Protect, Axis, RTSP/RTSPS | Discovers cameras, negotiates media sessions with brokered CNPG credentials, and relays H.264/H.265 streams over mTLS. See [UniFi Protect](./unifi-protect.md) and [Credential Management](./credentials.md). |
| **Storage** | `serviceradar-nvr` StatefulSet | Local fMP4 spool + S3 archive | Seals `init.mp4`, `media.m4s`, and `descriptor.json` blocks; verifies S3 uploads via readback; serves scoped `:8445` analysis reads; enforces retention watermarks and `RecordingHold`. See [Camera Recording & NVR](./camera-recording.md). |
| **GPU Inference (Stage 1)** | `serviceradar-media-worker` | Pure-Rust Candle CUDA (`YOLOX-x` + `SigLIP`) | Decodes sealed blocks via Fragment Read Grants, runs object detection (`Person`, `Vehicle`, `Animal`, `Package`) and `SigLIP` frame embeddings, and publishes to `media.results.>`. |
| **GPU Inference (Stage 2)** | `serviceradar-camera-vlm` | `crane-serve` (`Qwen3.5-4B`) | Generates natural-language scene captions, caption embeddings, and structured JSON answers for declarative Vantage ML pipelines. |
| **Control Plane** | `core-elx` `EventWriter` + `web-ng` | NATS JetStream -> CNPG + LiveView | Projects `media.results.>` into searchable CNPG tables and serves live WebRTC/WebSocket video, HLS v7 VOD playlists, hybrid search, ROI zones, and legal holds. |

### Storage and Retention Guarantees

| Guarantee | Mechanism |
| --- | --- |
| **Crash-safe media sealing** | Fragmented MP4 blocks (`init.mp4`, `media.m4s`, `descriptor.json`) are sealed on replicated local storage before indexing or archival. |
| **Readback-verified S3 archive** | Archived objects are verified on readback before local spool watermarks can reclaim capacity. |
| **Immutable legal holds** | `RecordingHold` pins matching intervals across both local spool and S3 archive, blocking retention eviction until explicitly released. |
| **Audit provenance** | Timeline intervals carry explicit `received` time-basis provenance, and every playback playlist request logs a `RecordingAccessAudit` entry. |
| **Network correlation** | Every camera source links to its underlying ServiceRadar inventory device so PoE port health, link flaps, and recording gaps correlate in one view. |

## Playback, Timeline, and Noise Reduction

The investigation console at `/cameras/:camera_source_id/recordings` pairs
low-latency live video with frame-accurate forensic scrubbing:

- **Live WebRTC with WebSocket fallback**: Streams directly from the camera
  relay and falls back automatically when a browser cannot reach the cluster
  peer. See [WebRTC TURN Relay](./webrtc-turn-relay.md).
- **Vertical Precision Timeline & Filmstrip**: Newest-at-top coverage scrubber
  rendering local, archived, pending-archive, gap, and retention-deleted spans
  (`15m`, `1h`, `6h`, `24h`, `7d`) alongside a synchronized horizontal thumbnail
  filmstrip and `+`/`-` zoom.
- **Tiered Smart / Motion Event Rail**: Coalesces detections into **Smart**
  (`Person`, `Vehicle`, `Animal`, `Package`) and **Basic** (`Motion`,
  `Recording`) clips under separate server-side budgets so high-volume motion
  never crowds out smart events.
- **Frame-Accurate HLS Clip Overlays**: Clips play from HLS v7 playlists
  carrying `#EXT-X-PROGRAM-DATE-TIME` tags. The player locks each decoded video
  frame timestamp to indexed bounding boxes so `AI boxes` track moving subjects
  during play, pause, and frame-stepping.
- **12x8 Detection Zones ROI Grid (Non-PTZ)**: Operators paint **Focus** and
  **Ignore** cells directly on a camera snapshot to suppress roadways or
  foliage before clip promotion and alerting.
- **Stationary-Vehicle Suppression**: Combines **motion-overlap** checks with
  **centroid-displacement gating** across consecutive frames so parked cars do
  not emit repeated `Vehicle` events while arriving or departing vehicles still
  trigger normally.

## Hybrid Semantic Action Search

Operators query recorded footage with plain natural language (for example,
`"person walking dog"` or `"white delivery van backing into loading bay"`).
Vantage fuses three independent retrieval signals with **Reciprocal Rank Fusion
(RRF)** so lexical precision, semantic intent, and visual similarity reinforce
one another without brittle score calibration.

![Hybrid RRF semantic action search across BM25, caption embeddings, and SigLIP visual embeddings](/img/vantage-hybrid-rrf-search.svg)

*Figure 2 -- Three parallel local scoring lanes merged via Reciprocal Rank Fusion into peak-frame clips and `#EXT-X-PROGRAM-DATE-TIME` bounding-box playback.*

| Lane | Signal | Source | Strength |
| --- | --- | --- | --- |
| **01** | `tsvector` BM25 | Indexed object labels, scene captions, and observation attributes | Exact keyword, plate text, and structured attribute recall. |
| **02** | Caption Embedding Cosine | `serviceradar-camera-vlm` (`Qwen3.5-4B`) scene descriptions | Natural-language action and intent matching. |
| **03** | `SigLIP` Visual Cosine | `serviceradar-media-worker` visual frame embeddings | Cross-modal visual recall for details not named in captions. |

## Vantage ML Extensibility and `serviceradar-sdk-vantage`

Custom vertical video analytics -- such as Automatic License Plate Recognition
(ALPR), PPE compliance, hazard monitoring, or bay guidance -- ship as signed
**Solution Packs** (`pack_format_version: 1`). Pipelines declare selectors,
Stage 1 triggers, ROI zones, and rate limits in `vantage_pipelines/*.json`
(`ServiceRadar.Camera.VantagePipeline`) and emit structured results solely
through `media.results.vantage.v1` -> `core-elx` `EventWriter` ->
`platform.camera_vantage_observations`.

![Three progressive Vantage compute ramps converging into JetStream observations and signed Solution Packs](/img/vantage-sdk-three-ramps.svg)

*Figure 3 -- Progressive compute ramps sharing one canonical JetStream subject, CNPG observation schema, SRQL entity, and signed `.srpack` distribution format.*

### Three Progressive Compute Ramps

| Ramp | Execution Model | Media Access | Credentials | Best For |
| --- | --- | --- | --- | --- |
| **Ramp 1: Declarative VLM** | Zero-code JSON pipeline executed by `serviceradar-camera-vlm` (`Qwen3.5-4B` or OpenAI-compatible VLM) on **full-resolution cropped IDR keyframes** with multi-frame track consensus. | In-cluster crop extraction (avoids `480x270` thumbnail ceiling) | None | Rapid prototyping, OCR/ALPR, PPE checks, and scene classification with no custom container. |
| **Ramp 2: External Worker (`vantage.worker.v1`)** | Out-of-process Rust or Python worker built with `serviceradar-sdk-vantage` (Rust core crate + PyO3 bindings + synthetic dev harness). | Scoped **Fragment Read Grants** (`POST /v1/media/workers/read-grants`) with SHA-256 verification; supports `:recorded_block` and `:live_keyframe_tap`. | Zero DB credentials | High-throughput or specialized models (Candle, ONNX, TensorRT, PyTorch) isolated across a process/network boundary. |
| **Ramp 3: WASM Action Bridge** | Sandboxed `wazero` plugin (`serviceradar-sdk-go` / `serviceradar-sdk-rust`) consuming observations and OCSF events. | Observation & event payloads | Brokered CNPG credentials only | Deterministic watchlist matching, webhook signing, ticket creation, and gate/relay triggers. |

### Reference ALPR Solution Pack (`io.serviceradar.vantage-alpr`)

ServiceRadar ships an Apache-2.0 reference pack, `io.serviceradar.vantage-alpr`,
bundling `vantage_pipelines/`, `signal_schemas/`, OCSF alert rules, and an
optional Dashboard SDK camera module in one ed25519-signed `.srpack`:

- **Starts on Ramp 1**: Triggers on Stage 1 `vehicle` detections, crops
  full-resolution IDR keyframes, and runs structured JSON extraction against
  `serviceradar-camera-vlm` with multi-frame track consensus.
- **Upgrades to Ramp 2 with zero downstream changes**: Deploying a compatible
  `vantage.alpr.v1` external worker routes pipeline jobs to the worker
  automatically while preserving the exact same SRQL queries, timeline markers,
  and alert rules.

### Querying Observations with SRQL (`in:camera_observations`)

| Use Case | SRQL Query |
| --- | --- |
| Recent ALPR reads on a gate camera | `in:camera_observations pipeline:"alpr" camera:"cam-north-gate-01" time:last_24h` |
| High-confidence reads across a site | `in:camera_observations site:"site-a" signal_type:"license_plate_read" confidence:>=0.90` |
| Exact synthetic plate lookup | `in:camera_observations pipeline:"vantage-alpr" plate_text:"ABC-1234" time:last_7d` |

Synthetic observation record in `platform.camera_vantage_observations` for
camera `00000000-0000-0000-0000-000000000001` (`cam-north-gate-01`, `site-a`,
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
- [Credential Management](./credentials.md) -- unified CNPG credentials and
  brokered access rules.
- [Roles & Permissions](./rbac-and-roles.md) -- camera live, playback, and
  legal hold RBAC permissions.
