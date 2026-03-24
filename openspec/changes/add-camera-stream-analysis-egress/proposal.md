# Change: Add camera stream analysis egress from relay sessions

## Why
The camera relay work gives us an edge-routed ingest path and Membrane-owned relay sessions in `serviceradar_core_elx`, but operators also want to peel off live streams for processing beyond human viewing. That includes frame analysis, object detection, scene understanding, and external AI pipelines.

This should be modeled separately from viewer delivery. Browser playback is one consumer of a relay session, while analysis pipelines are another. Keeping those concerns separate will let us add analysis taps, frame extraction, and external worker integration without destabilizing viewer playback or the edge media uplink contract.

Boombox may be useful as one implementation option for bridging relay media into external processing systems, especially Python-driven AI workflows, but we should define the platform contract first rather than hard-coding one tool choice into the architecture.

## What Changes
- Add a new analysis/processing capability on top of existing camera relay sessions in `serviceradar_core_elx`.
- Define relay-scoped analysis branches that can sample, downscale, or extract frames from active camera sessions without requiring a second camera pull from the agent.
- Define an external processing contract for sending media-derived artifacts or frame samples to analysis workers and ingesting resulting detections/events back into platform observability state.
- Add operational requirements for bounding analysis load so processing taps do not starve viewer playback or overload active relay sessions.
- Evaluate Boombox as an implementation option for external analysis bridging, but keep the spec tool-agnostic.

## Impact
- Affected specs:
  - `camera-streaming` (modified)
  - `observability-signals` (modified)
  - `edge-architecture` (modified)
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
  - `elixir/web-ng/**` (if analysis results are surfaced in UI)
  - external worker / integration code paths to be determined
- Dependencies:
  - Builds on `add-camera-stream-relay`
  - Compatible with the planned WebRTC viewer egress work
  - Does not require changes to the existing edge uplink or Wasm media bridge contract
