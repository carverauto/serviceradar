# Change: Independently scalable cloud and customer-operated recording

## Why

The existing bounded capture path records on the core replica owning a live
relay. Its storage safety primitives are useful, but neither this placement nor
continuous recording has been qualified for thousands of cameras. Recording
bandwidth, disk pressure and recovery must scale independently of core, viewers
and optional analysis.

Users must be able to choose cloud recording with S3, customer-operated recording
with durable local storage, or customer-operated recording with S3 archival.
Long archive retention is not a requirement to keep the same duration on hot
local disks when S3 is the durable destination.

## What Changes

- Introduce a separately deployable recorder service/pool, with explicit
  camera/profile assignment, multidimensional capacity admission and fenced
  ownership handoff. Reuse the current media/storage contracts, not a second
  recorder implementation inside a stateless plugin.
- Separate recording placement from storage policy. Support cloud + S3,
  on-prem + local, and on-prem + S3 without requiring SaaS for a fully on-prem
  deployment. Customer hardware is a first-class placement option.
- Keep continuous recording alive without viewers, reuse one upstream ingest per
  source/profile, and isolate live-view and analysis consumers.
- Make Membrane fan-out mandatory: additional viewers never create additional
  camera source sessions or edge-to-cloud live uplinks for the same profile.
  Serve customer-hosted live and recorded media through agent-originated
  connections; Cloud requires no inbound path into the customer network.
- Define segmented archive playback with bounded read-ahead and shared immutable
  fragment caching. S3 playback does not require restoring a whole recording to
  local disk, and cache pressure must not compete with recording reserves.
- Use bounded filesystem spools and restart-safe upload journals. S3-backed
  buffers cover a declared outage/recovery window; local-only storage retains
  the configured recording history and must be sized accordingly.
- Remove JetStream Object Store media staging from the pending edge plan. NATS
  carries bounded metadata, jobs and telemetry; recording bytes never use it as
  a media buffer or forwarding queue.
- Preserve honest gaps, separate local/archive/index availability, and maintain
  the existing authorization, archive integrity and preservation contracts.
- Scope Cloud enrollment, resource admission, storage custody, metering and
  lifecycle changes before hosted rollout. Keep detection/transcription in
  independent bounded CPU/GPU worker pools.

This is a proposal only. No recorder, storage resource, migration or deployment
is enabled by these changes. Implementation requires review/approval and the
qualification gates in [tasks](tasks.md).

## Impact and related work

- Affected capabilities: camera-recording, camera-streaming, vms-media-workers
  and vms-cloud-resources. [Design](design.md) owns the proposed boundaries;
  [capacity and acceptance](capacity-and-acceptance.md) owns synthetic proof.
- Product implementation areas: source/relay routing, a new recorder release,
  assignment and admission owners, durable local storage/publication, upload
  reconciliation, playback availability and worker dispatch.
- Cloud changes live in `serviceradar-control`; [Cloud scope](cloud-scope.md)
  assigns responsibilities without adding runtime multitenancy.
- Preserve [VMS foundation](../add-vms-storage-playback-engine/proposal.md),
  [edge archive](../add-edge-recording-archive/proposal.md), and
  [persistent spool safety](../add-persistent-camera-spool/proposal.md).
  Pending deltas are reconciled in this PR so they cannot later restore an
  object-store-only or JetStream-media requirement.
- Upon approval, the dedicated recorder is the production scaling path. The
  existing core-attached capture and optional core spool track remain bounded
  compatibility/validation work; converting core to a StatefulSet is not a
  prerequisite for this new recording tier. Preserve their existing checks and
  implementation evidence; do not relabel unimplemented work as shipped.
