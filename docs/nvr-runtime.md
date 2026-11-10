# NVR runtime and replicated storage

The `serviceradar-nvr` service runs as a StatefulSet. Each ordinal owns a distinct
retained PVC and a provisioned storage-lifetime UUID. Increasing the NVR replica
count adds worker capacity; it does not replicate or move existing recordings.

The storage provider owns data replication. Use a qualified replicated CSI class
such as Longhorn or Ceph RBD. Local-only retention does not require S3. When S3
is selected, the same protected PVC retains unarchived footage and its journal.
An ephemeral spool would still lose that backlog on node loss.

## Required durability

Qualification must demonstrate survival of one worker node and its local disk,
with surviving storage replicas on other nodes. Confirm actual replica placement,
healthy copies, acknowledged-write durability, capacity reserves, volume fencing,
reattachment and journal recovery. Longhorn configuration and replica health, not
just a `longhorn` class name, establish the protection. Ceph requires equivalent
pool and failure-domain qualification. NVR implements no application-level media
replication. These providers are examples; this checkpoint does not certify an
installed storage system.

Retain PVCs on scale-down and StatefulSet deletion. Use a retaining PV lifecycle
and preserve storage identities. Never force-detach a volume or activate a second
writer solely because a pod or heartbeat disappeared. Replacement must establish
exclusive attachment, verify the original marker and reconcile the original
assignment and pending blocks. Surviving footage and uninterrupted capture are
different claims: recorder downtime and in-flight uncommitted media may be gaps.

## Deployment checkpoint

The Helm `nvr` component is disabled by default. Enabling it starts the runtime
and health probes only. Pool enrollment, authenticated media ingress,
local catalog publication, S3 upload and automated restart
reconciliation remain pending. Do not enable recording policies through this
runtime yet. Workload updates use `OnDelete` until coordinated drain/fencing is
implemented.

The finite-session runtime enforces a per-replica spool budget and a physical
free-space floor. Capture admission also reserves 64 KiB for each missing
publication intent and 512 bytes for each missing acknowledgement, including
retained blocks discovered after restart. Publication spends its own allowance
while preserving the others. A single supervised publication task performs media
verification and syncs outside capacity accounting, so capture and rotation can
continue. Its pending bytes stay reserved until task exit, with a thirty-second
deadline even if the caller disappears. Saturation refuses new publication work;
recovery remains exclusive. These logical byte reservations do not preallocate
filesystem blocks or replace filesystem/recovery overhead sizing.
`nvr.maxSpoolBytes` defaults to 1 GiB and `nvr.reserveBytes` to
64 MiB. These integer byte settings configure admission, not PVC size: choose
budgets below the actual qualified filesystem capacity with room for metadata,
control and recovery. A complete block reservation includes media, init and
journal. Concurrent workers cannot independently spend the same remaining
budget. Existing files, including failed-session tails, remain charged after
worker or service restart. Admission never deletes files to make space.
Full blocks are sealed and their successors are admitted against fresh inventory,
without renewing the session deadline. See the
[runtime boundary](../elixir/serviceradar_nvr/README.md#runtime-boundary) for local
block notifications and their publication/recovery limits.

Read-only [restart discovery](../elixir/serviceradar_nvr/README.md#read-only-restart-discovery)
can enumerate retained block IDs and verify sealed snapshots without saved
notifications. It preserves incomplete or corrupt evidence and grants no
publication, playback or replacement-writer authority. Automatic reconciliation
and authenticated remote delivery remain pending.

The read-only [publication recovery pages](../elixir/serviceradar_nvr/README.md#recovering-publication-work-after-restart)
distinguish pending intents, matching retained acknowledgements, absent records
and unresolved evidence after restart. Begin with a nil cursor, consume the
storage-bound cursor to the end, and periodically rescan from nil to observe
concurrent changes. A cursor is progress through an observation scan, not an
acknowledgement or permission to discard records. Pages share the existing read
admission/deadline; reduce the page size after a timeout and preserve unresolved
entries for reconciliation.

The inventory is intentionally limited to 4096 block directories and known spool
file names. Unrecognized or unreadable entries stop admission for operator
reconciliation. This is not journal reconciliation, archival, retention or a
long-running recording capacity qualification. The free-space floor uses GNU
coreutils probes, refreshed at admission and at most once per second by write
guards. Admission needs the floor plus all full reservations free; an admitted
worker then writes into its media reservation while preserving the configured
floor and pending publication headroom.
It does not preallocate reserved blocks or fence unrelated volume users.
See the [runtime envelope](../elixir/serviceradar_nvr/README.md#resource-envelope)
for conservative accounting and process-restart behavior.

Example values (invented storage identities):

```yaml
nvr:
  enabled: true
  replicas: 2
  storage:
    storageClassName: longhorn
    size: 100Gi
    storageIds:
      serviceradar-nvr-0: 00000000-0000-4000-8000-000000000011
      serviceradar-nvr-1: 00000000-0000-4000-8000-000000000012
```

Choose fresh deployment-owned UUIDs during provisioning; do not reuse these
example values. Adding an ordinal requires its own UUID before rendering. Never
change an existing ordinal's UUID to make a conflicting mount pass startup.
Chart rendering requires distinct identities and explicit storage selection; it
does not inspect or attest a live storage provider. No bucket or S3 credential is
required for this local configuration.

The mount is `/var/lib/serviceradar-nvr`. Provision its `spool` child as an empty,
private directory owned by uid/gid 10001, mode 0700. Explicitly call the shipped
`ServiceRadarRecording.Storage.initialize/2` with that path and the ordinal's
UUID before admission. Startup and readiness call `Storage.open/2` only; they
never create or repair a marker. The parent mount's permissions may be managed by
CSI/fsGroup; do not recursively change permissions on retained blocks.

For a host installation, configure `SERVICERADAR_NVR_SPOOL_ROOT` and
`SERVICERADAR_NVR_STORAGE_ID`. Kubernetes instead sets the pod's member name and
a JSON `SERVICERADAR_NVR_STORAGE_IDS` map; the application requires an exact member
entry and refuses simultaneous scalar/map configuration. Neither setting holds
camera or provider credentials. Health probes listen on port 8095 by default.

## Qualification before rollout

Use synthetic footage to verify that a committed spool and its journal recover
on another worker after loss of the original worker and disk. Check restored
fragment hashes and decoded media, then exercise stale-writer fencing, backlog
recovery, storage exhaustion and explicit gap reporting. Retain evidence outside
the source tree. This physical failure test and a deployed-camera test require a
separate authorized rollout; this PR's release and Helm tests do not substitute
for them.

Storage references: [Longhorn replica placement](https://longhorn.io/docs/1.13.0/concepts/)
and [StatefulSet storage semantics](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/).
