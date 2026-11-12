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
  recovery:
    existingConfigMap: synthetic-nvr-recovery
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
Chart rendering requires distinct identities, explicit storage selection and an
operator-owned recovery ConfigMap; it
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

## Deployment recovery gate

NVR requires deployment-owned recovery state before runtime admission. Kubernetes
sets `nvr.recovery.existingConfigMap` to an existing ConfigMap with `generation`
and `state.json` keys. Helm never creates that ConfigMap or changes it to ready.
Keep it outside the CNPG/PVC backup set and outside application GitOps rollback.
The container pins `generation` in `SERVICERADAR_NVR_RECOVERY_GENERATION` at boot
and mounts the ConfigMap directory read-only, without `subPath`, so changes to
`state.json` can propagate to existing pods.

Standalone installations set `SERVICERADAR_NVR_RECOVERY_GENERATION` to a canonical
UUID and `SERVICERADAR_NVR_RECOVERY_STATE_FILE` to an absolute, deployment-managed
file outside the media spool and its restore set. Atomically replace this file;
keep it writable only by trusted deployment control. Projected-volume symlinks
are supported. Path validation rejects lexical spool descendants, but cannot
prove independent backup provenance or resolve an operator's failure domains.

The file is at most 256 bytes. Admission requires exactly the compact canonical
JSON below, with no trailing newline or additional keys, and the generation must
match the process's boot-pinned value. This invented example illustrates the
format; it is not a command to open a deployed recorder:

```json
{"generation":"00000000-0000-4000-8000-000000000077","state":"ready"}
```

Use `"state":"closed"` to close the gate. Missing, unreadable, malformed,
noncanonical, oversized or different-generation state also returns
`:nvr_recovery_closed`. Omitting both settings permits the process to start but
keeps admission closed; partial or invalid settings fail boot. `/healthz` remains
live while `/readyz` refuses closed state. Valid ready state is only this gate's
prerequisite: bootstrap/history barriers and storage/assignment authority still
apply. Offline bootstrap evidence operations remain available while closed.

The runtime re-reads state for admission and each writer pressure check, even
when the disk-pressure measurement is cached. Read tasks check before work and
before returning results; publication delivery checks before each HTTP attempt.
No ready result is cached. Closing the gate cannot recall bytes already returned,
cancel kernel I/O, or retract an HTTP request already sent. ConfigMap projection
is eventual, and API update success is not proof that replicas observed closure.

Before deliberate CNPG PITR or volume snapshot restore, deployment recovery must
close the gate, quiesce and retire every authority-bearing process, then establish
a fresh generation outside the restored backup set. Old processes refuse the new
generation even if its state later becomes ready. Ordinary process restart or
qualified worker replacement uses the existing generation; it does not require
manual reopening merely because a pod changed. If deployment control is also
restored, establish fresh closed state before starting consumers.

This checkpoint implements the NVR consumer and deployment file wiring only.
The operator recovery command, Core consumers, current-history reconciliation,
per-storage completion and cross-replica quiescence verification are pending.
Do not use the example ready record to bypass those prerequisites or remove the
bootstrap barrier. A coordinated rollback of every trust source cannot be
detected from matching old data alone. Restore qualification and deployment
remain separate explicitly approved work.

## Private publication receiver

Web-ng can receive canonical local-publication intents on a separate private
HTTPS listener. It is disabled by default and is outside the public API and
browser router. Explicit and opt-in automatic NVR delivery are described below;
assignment and local-copy catalog reconciliation remain pending.

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
storage, a second media copy or deletion permission. This API does not receive
assignments or publish a local-copy catalog. Synthetic release tests exercise the sender over real TLS against a
protocol fixture; the receiver's own database tests cover Core commit semantics.

## Automatic pending intent delivery

After installing the sender configuration above, opt in with
`SERVICERADAR_NVR_PUBLICATION_AUTO_DELIVERY=true`. It defaults to `false`; other
values, or enabling it without storage and delivery configuration, fail startup
with `:invalid_nvr_auto_delivery_config`. This flag does not provision storage,
create publication authority or start capture. Helm and Compose do not enable it
by default.

The supervised coordinator visits one entry from `publication_page(cursor, 1)`
per step. It shares the single delivery slot and thirty-second worker deadline
with explicit calls, including the scan itself. Pending entries use the existing
verified sender. Matching retained acknowledgements are skipped; unprepared or
unresolved entries remain unchanged for reconciliation. Explicit delivery still
contacts the receiver even if an acknowledgement exists locally.

A completed page advances the cursor even when its delivery fails, so a rejected
intent does not pin later work. The last page wraps to nil; a scan error, unknown
worker outcome or coordinator restart also starts again from nil. The original
intent and operation ID remain the retry authority. An admitted worker may finish
after coordinator loss under its own deadline. The replacement coordinator backs
off if that slot is still occupied and never queues another worker. Losing the
coordinator does not restart earlier recording/capacity workers.

Steps normally wait 1,000-1,249 ms. Consecutive scan, admission or delivery failures
double that base, capped at 48 seconds, with up to 25 percent jitter; the maximum
wait is 59,999 ms. Any completed non-error classification resets the failure
streak. Permanent HTTP rejections are not retried within a delivery operation,
but remain pending for a later scan. This allows recovery after authority or
configuration is repaired without replacing the retained operation.

`ServiceRadarNVR.publication_delivery_status/0` returns `{:ok, status}` with
`cursor`, `active?`, `last_result`, `failures`, `steps`, `delivered` and `delay_ms`.
`steps` counts completed workers, including failures; rejected admissions do not
increment it. `delay_ms` is the last scheduled delay, not a countdown. Counters
and cursors reset on restart; this status contains no intent, token or certificate
bytes. Disabled or restarting coordinators return `:nvr_scheduler_unavailable`.

Each verified page inventories up to 4,096 directories and rehashes the selected
media; pending delivery verifies it again. This conservative first scheduler has
not qualified large-backlog catch-up throughput. Even without errors, a full
4,096-entry cycle takes over an hour at this cadence. A block that cannot pass
verification remains unresolved; no background repair or destructive cleanup is
implied. Publication acceptance is still not playable local-copy availability.

## Local storage binding identity

Core's internal `ServiceRadar.Camera.LocalStorageBinding.register/2` provisioning
API retains a binding UUID for each `(storage_id, generation)`. Its version-1
configuration contains exactly `schema_version`, `storage_id`, `generation`,
`provider_resource_ref` and `profile_sha256`. The profile digest covers the complete
canonical provider configuration and failure profile. The provisioning adapter
must validate the opaque provider reference and compute that digest before calling
this API; the parser does not inspect a provider or interpret the reference as a
filesystem path or URL.

Identical retries return the same binding UUID, content digest, original
`provisioned_by` and insertion time, including after an authorized provisioning
principal rotates. A changed provider reference or profile under the same storage
UUID and generation conflicts. Retain the old generation and create a new one for
changed configuration; a newly initialized empty volume needs a new storage UUID,
even when a PVC or StatefulSet ordinal is reused. Generations are immutable labels,
not an implicit latest/current selection.

The trusted caller supplies an authenticated system actor with
`nvr_storage_purpose: :provision` and `nvr_storage_id` matching the exact storage
UUID. These fields must come from deployment authentication/configuration, never
from the request body. Generic system actors and recorder identities cannot
register or retry bindings. Reads are limited to the actor's storage lifetime.
There is no external provisioning endpoint or automatic registration at startup.

This resource is identity evidence only. It has no update, deletion or activation
action and grants no qualification, recording, local-copy registration or playback
permission. Scoped activation and withdrawal are separate decisions; see
[Current local storage qualification](#current-local-storage-qualification).
Existing installations stay unqualified; accepted publication intents and S3
archive state keep their existing meanings.

## Local storage bootstrap preparation

Core's internal
`ServiceRadar.Camera.LocalStorageBootstrapPreparation.prepare(operation_id, binding_id, actor: provisioner)`
retains one immutable preparation per storage lifetime. The provisioning caller
chooses an operation UUID once and recovers that same operation on retries. Core
loads the binding through the caller's storage scope; it derives the storage UUID
and principal from trusted actor configuration. The same `:provision` purpose
used for bindings is required. Recorder and qualification principals cannot
prepare bootstrap operations, and reads remain provisioning/storage scoped.

The retained canonical JSON has exactly `version: 1`,
`kind: "local_storage_bootstrap_prepared"`, `operation_id`, `storage_id`,
`binding_id` and `binding_sha256`. `record_sha256` is the lowercase SHA-256 of
those exact bytes. The bounded record contains no provider reference or path.
Core persists the record before returning it. It is correlation evidence from a
trusted control caller, not a signature or a remote authentication mechanism.

Exact retries return the original record, principal and insertion time, including
after credential rotation. A different operation or binding for the same storage
UUID conflicts; an operation UUID cannot be reused for another storage lifetime.
There is no update or deletion action, and the binding has a restrictive foreign
key so retained provenance cannot be silently removed.

Preparation alone does not attest that the volume is empty or that history is
reconciled. It writes no volume marker and grants no capture, publication,
playback or deletion authority. The separate volume-side installer below retains
those bytes, but two-sided completion remains unimplemented. Matching durable
control-plane and volume completion must precede capture. A retained spool needs
supported history reconciliation even if it has a preparation; a missing history
file is never permission to bootstrap it. No startup path invokes this action.

### Explicit new-volume installation

`ServiceRadarNVR.bootstrap_storage(root, reference, preparation)` is a trusted,
offline provisioning API. The provider must exclusively attach the new volume,
retire previous writers and provide an existing private empty spool directory.
The caller authenticates Core and supplies its exact canonical preparation bytes;
`reference` is trusted configuration with `:storage_id`, `:binding_id` and
`:binding_sha256`. Parsing validates correlation only, not Core origin or physical
provider identity. This operation is not exposed over HTTP or called at startup.

The installer accepts at most 512 preparation bytes. It exclusively creates
`.bootstrap-preparation.json`, syncs that file and the root directory, then
exclusively creates the existing 37-byte `.storage-id` marker. Both files use
mode 0600. It syncs the marker and directory and verifies storage identity before
returning the storage handle and preparation SHA-256. The preparation must become
durable first: a later interruption must not leave a usable legacy spool.

An exact retry syncs the original bytes without rewriting either file. A complete
preparation with a missing marker can finish installation. A partial or changed
preparation/marker, symlink, hard link or non-private file remains untouched and
refused. An existing spool, including a directory containing only `.storage-id`,
cannot acquire a preparation through this API. Unexpected entries are preserved.
Provisioning must reconcile failures; deleting evidence to force a retry is not
a supported recovery procedure.

An installed bootstrap preparation keeps NVR inventory and write admission closed
with `:nvr_history_bootstrap_incomplete`. No capacity is advertised and no media
reservation can omit its retained control bytes. This checkpoint does not yet
complete Core history, enable recording, qualify storage, or authorize playback
or deletion. Packaged-release tests cover installation, exact retries in fresh
VMs, interruption states and refusal paths; they do not prove worker/disk-loss
durability. The provider qualification and supported restore protocol remain
separate work.

### Core installation acknowledgement

After the offline installer returns success, the trusted provisioner can call
`ServiceRadar.Camera.LocalStorageBootstrapInstallation.confirm(preparation_id, preparation_sha256, actor: provisioner)`.
The caller must have observed the synced preparation and marker under exclusive
attachment with previous writers retired. Core cannot inspect those files: the
digest correlates the report with its preparation, and the scoped provisioning
principal is responsible for the installation attestation. Recorder and
qualification principals cannot confirm installation.

Core checks the exact preparation UUID and lowercase digest within the actor's
storage scope, then commits one immutable acknowledgement per storage lifetime.
The canonical JSON contains exactly `version: 1`,
`kind: "local_storage_bootstrap_installed"`, `operation_id` (the preparation UUID),
`storage_id` and `preparation_sha256`. It is bounded to 512 bytes, and
`record_sha256` hashes those exact bytes. A restrictive foreign key preserves the
original preparation. Reads use the same provisioning/storage scope.

Exact retries return the original bytes, confirming principal and insertion time,
including after credential rotation or a later binding generation. A missing or
foreign preparation or mismatched digest is rejected even after a successful
confirmation. There is no update or deletion action and no network endpoint or
automatic caller for this operation.

This is Core's installation acknowledgement, not a completed two-sided history
checkpoint or a storage qualification. Completion reconciliation remains
unimplemented; the offline persistence and evidence boundary is described below.
The volume's preparation barrier still refuses capture and inventory; Core does
not use this row to authorize registration, playback or deletion. Physical
provider failure recovery and retained-volume restore still need their own proof.

### Volume acknowledgement and evidence

After authenticating Core's response, trusted provisioning can call
`ServiceRadarNVR.acknowledge_bootstrap(root, reference, acknowledgement)` offline.
The recorder must remain stopped, attachment exclusive and previous writers
retired. The configured reference is the same storage/binding reference used for
installation. The acknowledgement must be the exact canonical Core record,
bounded to 512 bytes and matching the retained preparation's operation UUID,
storage UUID and SHA-256. Parsing proves correlation, not Core authentication.

The operation validates the retained preparation and marker, re-syncs both files
and the root directory, then exclusively creates `.bootstrap-acknowledgement.json`
with mode 0600. It syncs that file and the root and verifies storage identity
before returning evidence. Exact retries re-sync the original bytes without
rewriting files. An initial installation retry also accepts this completed prefix;
it cannot recreate a missing marker once an acknowledgement exists.

`ServiceRadarNVR.bootstrap_evidence(root, reference)` performs read-only inspection
of the same bounded records. It returns exact preparation and optional
acknowledgement bytes, their SHA-256 digests, storage and operation UUIDs, and state
`:prepared` or `:installation_acknowledged`. `used_control_bytes` counts the
37-byte storage marker plus the actual preparation and acknowledgement lengths.
`pending_control_bytes` reserves a maximum 512-byte acknowledgement when absent,
and is zero once retained. The maximum combined control allowance is 1061 bytes.
These are offline evidence counts, not a runtime capacity grant. Inspection does
not sync or repair files; observing complete bytes is not a successful persistence
retry or a physical durability proof.

Both APIs refuse roots containing media or unknown entries, missing or conflicting
records, non-private files, symlinks and hard links without deleting or repairing
them. Retained media requires separate reconciliation. Either bootstrap record
keeps inventory and recording admission closed, including an orphaned
acknowledgement. A historical installation acknowledgement cannot prove that Core's
current history survived a restore. Current-history reconciliation, runtime control
reservations and provider failure qualification remain separate work.

## Local storage qualification reports

Core's internal `ServiceRadar.Camera.LocalStorageQualificationReport.submit/2`
retains immutable evidence reports against an existing binding. Each version-1
document contains exactly `schema_version`, `binding_id`, `storage_id`,
`binding_sha256`, `profile_sha256`, `revision`, `evidence_sha256`,
`policy_revision`, `issued_at_ms`, `expires_at_ms` and `checks`. Binding and storage
UUIDs must be canonical; all three digests are lowercase SHA-256 hex. The policy
revision is a bounded ASCII token. Revision and timestamps are positive signed
64-bit integers, and expiry must follow issuance. The report digest hashes
canonical JSON with the `nvr-local-storage-qualification-report-v1` domain
separator. Evidence stays outside the report and is identified by its digest.

The checks map records each required outcome independently:

- `acknowledged_writes_survive_worker_disk_loss`
- `replica_placement_and_health`
- `provider_attachment_fencing`
- `application_writer_ownership`
- `reattachment_preserves_identity_and_bytes`
- `retained_volume_lifecycle`
- `restore_preserves_history`

Each outcome is `passed`, `failed`, `not_tested`, `not_confirmed` or `unsupported`.
Unknown fields and incomplete checks are rejected. Expired reports and failed
checks can be retained as historical observations; retention does not evaluate
freshness or infer eligibility from passing outcomes.

The trusted caller supplies an authenticated system actor with
`nvr_storage_purpose: :qualify` and the exact `nvr_storage_id`. Deployment
authentication/configuration supplies these fields and the issuing principal,
never the document. Qualification principals can read bindings and reports only
for their scoped storage lifetime; they cannot provision bindings. Provisioning
and generic recorder actors cannot submit reports. There is no external report
endpoint or automatic qualification on startup.

Submission verifies that the retained binding matches the document's storage
UUID, binding digest and profile digest. Identical retries of `(binding_id,
revision)` preserve the original report UUID, `issued_by` and insertion time.
Changed content at that revision conflicts; another revision retains the earlier
report. A later revision is not an implicit current selection. The resource has
no update, deletion or activation action. Evidence assessment is described in the
next section; what it still leaves required before any profile can authorize
local-copy registration is listed there.

## Local storage evidence assessment

`LocalStorageQualificationReport.assess(report_id, health, actor: qualifier)`
loads the retained report through its storage-scoped read policy. The trusted
adapter must supply `actor.nvr_storage_policy` from deployment configuration,
never from the request. That policy has exactly four atom keys: `revision`,
`profile_sha256`, `max_report_validity_ms` and `max_health_age_ms`. The revision
and profile must match the report. Both limits are explicit positive signed
64-bit millisecond counts; no production defaults are supplied.

The health decision has exactly five string keys: `binding_id`, `report_sha256`,
`evidence_sha256`, `observed_at_ms` and `status`. It refers to the exact retained
binding/report, includes a lowercase SHA-256 evidence digest and a positive
signed 64-bit observation timestamp, and records `healthy`, `degraded` or
`unknown`. The qualification authority must verify this evidence before calling;
a recorder-supplied claim is insufficient. Raw operational telemetry still goes
through JetStream. Assessment neither probes the provider nor persists telemetry.

Assessment uses Core time. All seven report outcomes must pass. Report issuance
and health observation cannot be in the future; report validity cannot exceed
the policy limit. Evidence expires at the report expiry or the health observation
plus its maximum age, whichever comes first; the exact deadline is excluded.
Missing policy, missing/unknown/degraded health, malformed or mismatched evidence
and expired observations return an ineligible result with a bounded reason.

A successful result is `%{evidence_status: :current, valid_until_ms: deadline}`;
it is an assessment at that instant, not a reusable grant. The pure
`LocalStorageEvidence.evaluate/4` owns these rules so activation and future
registration can evaluate them against trusted transaction-time evidence.
Assessment does not select a current binding, activate a report, reverse a
withdrawal or advertise playable footage. Current decisions use the separate
operations below. Registration, an explicit
restore-horizon limit, restore reconciliation and actual provider qualification
remain required. Existing installations remain unqualified.

## Current local storage qualification

`LocalStorageQualification.activate(revision, report_id, health, actor: qualifier)`
selects a retained report for the actor's storage lifetime. The trusted adapter
supplies the same explicit policy and verified health evidence as assessment.
A conditional PostgreSQL upsert serializes decisions on the storage UUID across
all binding generations. The decision revision is a positive signed 64-bit
integer independent of report revisions. A higher revision replaces the current
decision; a stale revision or changed content at the same revision conflicts.
Activation checks evidence with Core time inside the transaction after acquiring
the row lock. Failure rolls back the entire decision.

`LocalStorageQualification.withdraw(revision, reason, actor: qualifier)` records
a withdrawn decision without requiring a policy or fresh evidence. The reason
is a bounded ASCII token. Withdrawal can precede the first activation, preventing
a delayed older activation from reviving eligibility. It leaves immutable
reports and media intact and does not release holds or retire writers. The
qualifier must withdraw when it learns that storage is degraded or unknown; a
rejected activation leaves the previous decision intact. Core does not poll the
provider in this operation.

An exact retry of the current decision returns its original issuer and time,
including when that decision's evidence has since expired. This is a historical
receipt, not renewed qualification. Changing policy or health requires a higher
decision revision. The row retains the policy snapshot used for activation.

`LocalStorageQualification.status(actor: qualifier)` returns `unknown` without
a decision, `withdrawn` after withdrawal, or evaluates an active decision against
Core time. A changed or missing trusted policy, expired report or expired health
makes it ineligible. Status is an advisory snapshot. Future registration must
lock this same storage row and recheck evidence, history and disposition in its
own transaction; this API does not admit recordings or advertise playable media.
No provider is qualified automatically and no policy limits are defaulted.

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
