# Change: Bounded camera recording and VMS/NVR storage

## Why

ServiceRadar has agent-routed live RTSP playback and analysis branches, but live
viewing does not provide recording retention, indexed replay, export or outage
recovery. Fixed cameras, vehicles and arbitrary dashboard media sources need the
same recording service. Temporary NATS Object Store staging must be explicitly
sized so video cannot consume the capacity needed for telemetry.

## What Changes

- Add recording policies, recorder leases, bounded media segments, a recording
  index and authorized timeline/playback/export APIs on the existing camera path.
- Retain video in deployment-configured S3-compatible object storage; keep
  metadata, access policy and retention workflow in CNPG/Ash.
- Support optional, finite JetStream Object Store staging for completed segments;
  never use it as an implicit unlimited recording archive.
- Support a disconnected edge recording profile: a local JetStream domain retains
  segments and a resumable archiver continuously drains them to permanent object
  storage whenever that destination is reachable, independently of hub connectivity.
- Define upload verification, crash recovery, expiry, gaps, quota admission and
  per-deployment byte/throughput/replica sizing before recording is enabled.
- Extend dashboard camera interfaces with playback/time-range operations that
  use the host's authorization and stable camera/object identities.

## Impact

- Affected specs: new `camera-recording`; existing `camera-streaming` relay remains the integration boundary.
- Affected code: agent camera reader/uploader, core relay lifecycle/media branches,
  Ash resources/migrations, object-store adapters, retention workers, web playback
  APIs and dashboard SDK.
- Reuses `add-showcase-demo-portfolio` D8/D9/D16 camera sources, viewers and analysis.
  Its explicit VMS non-goal remains valid: this separate change owns recording.
- Coordinates with `add-spatial-observation-ingestion` and the durable edge-record
  work for metadata/provenance; media bytes remain on the dedicated media path.
- Proposal only. No recording is enabled, no live media is copied, and no cluster
  resources or retention settings are changed by this change proposal.
