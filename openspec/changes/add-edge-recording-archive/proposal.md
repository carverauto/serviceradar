# Change: Edge recording with bounded filesystem storage and optional S3 archival

## Why

Issue #4914 extends the recording foundation to survive a configured disconnected
interval. This is not part of #4774 acceptance. The
[scalable recording proposal](../add-scalable-camera-recording-plane/proposal.md)
separates customer-operated placement from storage policy: retain locally, or
use bounded local buffering with S3 as the durable archive.

## What Changes

- Bind the host recorder/archiver to a qualified exclusive filesystem lifetime
  and durable pending-work journal, without central CNPG or remote quorum per segment.
- Remove the unimplemented JetStream Object Store media-staging option. NATS
  carries metadata, jobs and telemetry; video bytes stay on the filesystem/S3 path.
- Provision finite offline policy/credential windows and fenced ownership before
  disconnect; restart must not renew expired authority.
- For S3-backed mode, upload sealed segments promptly whenever S3 is reachable,
  independently of hub connectivity, with bounded persistent retry state.
- Verify media, initialization dependencies and recovery manifests; persist
  receipts before reclamation, with central index delivery retried separately.
- For local-only mode, use durable local publication/retention rather than require
  an S3 receipt. Size local disks for the actual retention policy.
- Bound bytes, segment sizes, in-flight work and outage windows; preserve telemetry
  reservations and expose pressure/gaps instead of silent eviction or growth.
- A NATS reconnect or PubAck is not archival proof. No media sourcing/mirroring
  through NATS is required or offered by this proposal.

## Impact

Edge recorder/archiver, filesystem journal, offline grants and optional S3 receipt
reconciliation. Depends on `add-vms-storage-playback-engine` and the placement,
local-publication and handoff contracts in `add-scalable-camera-recording-plane`.
Central playback availability is not required to finalize authorized local media.
No implementation or deployment is enabled by this proposal update.
