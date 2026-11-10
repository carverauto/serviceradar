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
publication, playback or replacement-writer authority. Explicit authenticated
delivery is available below; automatic reconciliation remains pending.

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

## Private publication receiver

Web-ng can receive canonical local-publication intents on a separate private
HTTPS listener. It is disabled by default and is outside the public API and
browser router. The explicit NVR sender is described below; automatic retry
scheduling and reconciliation remain pending.

Set `SERVICERADAR_NVR_PUBLICATION_ENABLED=true`,
`SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE` and
`SERVICERADAR_NVR_PUBLICATION_TOKEN_FILE` in the receiving web-ng process.
`SERVICERADAR_NVR_PUBLICATION_PORT` defaults to 4003. No Helm Service or ingress
exposes this port automatically. Restrict network access to recorder workloads.

The JSON installation file has exactly four fields: `cert_file`, `key_file`,
`ca_file` (absolute paths to server certificate, private key and client trust CA),
and `clients`. The latter maps lowercase SHA-256 fingerprints of client DER
certificates to their canonical storage UUIDs. It accepts 1 through 64 bindings;
certificate rotation may bind old and new fingerprints to the same original
storage lifetime. Each replica retains its own storage UUID. Installation files
are bounded to 32 KiB and are read on listener startup; restart to apply changes.
The separate token file contains a dedicated 32 through 512 byte printable ASCII
bearer token, with no newline. These are ServiceRadar workload credentials,
provisioned as infrastructure secrets, not camera/device credentials.

Send one `POST /v1/local-publication-intents` request with mutual TLS,
`Authorization: Bearer <token>` and `Content-Type: application/json`. The body is
at most 64 KiB of exact canonical intent bytes. The receiver derives the system
actor and storage binding from its installation, then checks the original frozen
Core block authority. A 200 response contains the canonical `intent_accepted`
acknowledgement only after the immutable receipt commits. An exact retry returns
the same acknowledgement, including after listener restart or a lost response.
The client must retain the original operation and intent bytes when an outcome
is unknown. This receipt does not establish playable availability, storage
qualification, archive success or permission to delete media.

Invalid authentication returns 401; a storage-binding mismatch returns 403;
malformed intents return 400; oversized bodies return 413; a missing original
block returns 404; unfrozen/conflicting authority returns 409. Other acceptance
errors return 503. A transport failure can hide a successful commit, so reconcile
by retrying the original operation rather than inventing a replacement.

The listener permits four concurrent connection handlers, one request per HTTP/1
connection, and no HTTP/2. Body reads have a five-second read timeout. Once the
request reaches the plug, an absolute ten-second deadline terminates its handler,
including blocked database work. TLS handshakes and header parsing precede this
deadline and retain the server's transport timeouts. Saturated connections can be
refused; the sender uses bounded retries. No background acceptance
worker survives a timed-out handler.

## Explicit NVR publication delivery

`ServiceRadarNVR.deliver_publication(block_id)` sends one retained intent to the
installed private receiver. It re-verifies local media and syncs the original
intent before sending the exact canonical bytes. It authenticates the receiver
with its CA and hostname, presents its client certificate and dedicated bearer
token, and persists only the matching canonical acknowledgement. An existing
local acknowledgement does not bypass authenticated delivery. Exact retries
preserve both records, including after restart or a lost response.

Delivery is disabled by default. Opt in with both
`SERVICERADAR_NVR_PUBLICATION_CONFIG_FILE` and
`SERVICERADAR_NVR_PUBLICATION_TOKEN_FILE`. The boot-time JSON file has exactly
these keys (paths below are invented installation examples):

```json
{
  "host": "core-publication.example.test",
  "port": 4003,
  "ca_file": "/etc/serviceradar/nvr/core-ca.pem",
  "cert_file": "/etc/serviceradar/nvr/client.pem",
  "key_file": "/etc/serviceradar/nvr/client-key.pem"
}
```

The host is a DNS name or IPv4 address matching the receiver certificate. HTTPS
and `/v1/local-publication-intents` are fixed; redirects are refused. Certificate
paths must be absolute. The token file contains 32-512 printable non-space ASCII
bytes (surrounding whitespace is trimmed within the 512-byte file limit). These
are infrastructure credentials for ServiceRadar talking to itself. The receiver
must trust the client CA, pin the client certificate to this storage UUID and
have the same bearer token installed. Restart to reload configuration and token;
certificate files are opened for each TLS connection, and the CA file (at most
64 KiB of PEM certificates) is decoded afresh, so a replaced CA stops being
trusted by the next connection. Partial or malformed
configuration fails startup rather than silently disabling delivery.

One supervised delivery task is admitted per replica, without a waiting queue.
Saturation returns `:nvr_delivery_capacity`. Its thirty-second absolute lifetime
includes local verification, sync, retries and acknowledgement persistence, even
if its caller exits. Recording admission and read slots remain independent.
Each connection/send has a five-second timeout; response reads share the
remaining five-second attempt budget. Responses have an 8 KiB header limit and a
512-byte acknowledgement limit; non-200 bodies are not read, so their size does
not affect retry. Transport failures, 408, 429 and 5xx responses
allow at most three attempts with 100/200 ms delays. Other statuses and invalid
acknowledgements are returned without retry. Errors never erase retained media
or replace a conflicting/partial record.

A timeout or lost response can hide successful acceptance or local persistence.
Inspect or retry the same retained operation; do not create a new operation ID.
An inner local read/publication task may finish under its own existing deadline
after the delivery task expires. No network task survives the delivery deadline.
The receipt proves intent acceptance only, not playable availability, qualified
storage, a second media copy or deletion permission. This API does not yet scan
pending intents, schedule retries, receive assignments or publish a local-copy
catalog. Synthetic release tests exercise the sender over real TLS against a
protocol fixture; the receiver's own database tests cover Core commit semantics.

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
