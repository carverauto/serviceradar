# Local publication, restoration and preservation

This defines task 1.4's implementation contract. It does not implement local
publication, retention or holds, qualify storage, or enable recording. The
standalone runtime currently seals and verifies bounded media, discovers retained
blocks and admits bounded reads; those operations do not advertise recordings.
Offline grants (1.3), authenticated transport (1.7), playback admission (1.8),
storage qualification and implementation (3.1-3.7) remain separate work.

## Owners and evidence

Core owns policy, assignment, the CNPG recording catalog and preservation intent.
The NVR owns bytes and durable local publication/disposition records on the
qualified retained filesystem. The storage provider supplies replication and
attachment fencing. CNPG replication does not replicate video, and NVR replicas
do not copy media to one another. Local-only publication requires no S3 service,
credentials, upload lease or object-store receipt.

| Evidence | What it establishes | What it does not establish |
| --- | --- | --- |
| Sealed media and canonical descriptor | Exact content, timing and initialization dependencies | Publication authority or node-loss durability |
| Frozen historical authority | Permission to reconcile that exact original recording | Permission to adopt unrelated bytes or perform future capture |
| Durable local publication record | Recoverable content identity and pending catalog operation on the original storage lifetime | A committed Core catalog entry or current reachability |
| Core catalog acknowledgement | Idempotent registration of the verified local copy | Playback permission or a second media copy |
| Durable preservation acknowledgement | The local disposition coordinator has pinned the covered bytes | Availability of footage already missing or permission to view it |

Reuse `RecordingBlocks`' original-recorder fence and immutable descriptor
semantics. The existing `ArchiveUploads.publish_archive` and
`RecordingBlock.archive_*` evidence describe verified object-store publication;
do not populate them with local receipts or weaken their checks. Core needs a
distinct local-copy publication contract/resource with its own proof. The shared
descriptor and archive manifest wire contracts remain unchanged.

Bind a local copy to the storage UUID, block ID and canonical descriptor SHA-256.
Retain the original source/profile, clock identity, recorder epoch, block sequence
and historical authority correlation. A pod name, ordinal, hostname or current
recorder address is routing metadata, not recording identity. Recovering a copy
never assigns it a new recording identity merely because its serving pod changed.

## Publication ordering

1. Admit capture only under the assignment and qualified exclusive storage
   lifetime. Seal and verify the journal, initialization dependencies, fragments
   and whole block before deriving the canonical descriptor.
2. Establish historical publication authority under the original recorder fence.
   Retain its exact correlation with the frozen descriptor. A later recorder
   generation cannot freeze an earlier owner's unknown block using its new lease.
3. Durably persist the local publication manifest and pending catalog operation,
   including the immutable copy tuple and historical authority correlation.
   Flush the records and required filesystem namespace changes before reporting
   this boundary complete. Reserve control/journal capacity independently of
   media capacity so the operation cannot be accepted without a durable record.
4. Deliver bounded metadata over the authenticated control path. Core verifies
   the exact content, authority and storage binding, then commits the local-copy
   catalog registration. File/network I/O never runs inside a CNPG transaction.
5. Return a stable acknowledgement bound to that operation and content. Persist
   it locally before compacting pending delivery state. Retain the recoverable
   manifest, authority correlation and preservation/disposition history for the
   supported restore horizon.

An exact retry returns the same registration. Reusing an operation identity with
different content is a conflict and preserves the evidence. A crash or lost
acknowledgement reconciles the original operation; it does not overwrite content
or create another logical recording. Pending publication is bounded by count,
bytes and age, with explicit admission/backlog reporting. Saturation stops new
affected admission and reports gaps; it never evicts unindexed media to make the
queue appear healthy.

Advertise a local recording only after verified durable local evidence and Core
catalog registration agree. A queued notification or successful seal is not
availability. Track publication, present reachability and preservation separately:
a registered recording can be temporarily unreachable or later corrupt. Every
catalog/manifest/byte request still requires fresh camera, recording-read and
interval authorization; a digest or old publication receipt grants none of it.

Capture does not wait for a catalog round trip for each frame or fragment.
During a control outage, preserved sealed blocks may remain unindexed. Blocks
without established historical authority remain unresolved until task 1.3's
provenance-checked reconciliation exists; this contract supplies no offline
grant, authority bypass or promise to publish all discovered bytes.

## Restore boundaries

A replacement NVR reattaches the same storage lifetime only after verified writer
retirement and exclusive attachment. It reconciles bounded pages of manifests,
pending operations and acknowledgements, verifies media and dependencies, and
registers current routing without changing historical identity. An identical pod
name on a new empty volume cannot serve the old recordings.

The supported recovery set includes media and initialization files, journal and
publication manifests, authoritative publication history, and preservation and
deletion history. Recover Core authority from the supported control-plane backup
and reconciliation procedure. A checksum or a manifest's reference to a former
authority is not itself proof that authority existed. A future independently
verifiable retained authority receipt requires its own defined verification and
key-lifecycle contract before it can replace control-plane history.

Control-plane backup/history retention must cover the supported media restore
horizon. Recovery must reconcile preservation/disposition checkpoints across
Core and the retained volume before advertising restored copies or authorizing
deletion. An empty or older catalog does not prove that no hold exists. An older
volume snapshot must not resurrect expired/deleted publication or regain stale
deletion permission. Until history is complete and consistent, preserve bytes,
report unresolved recovery and refuse publication and destructive operations.
Volume-only recovery without authoritative history is therefore a preservation
and inspection path, not an automatic catalog or permission restore.

Missing/corrupt media or dependencies remain unavailable with explicit affected
intervals even when a valid manifest survives. Missing manifests/authority leave
surviving bytes preserved for reconciliation; discovery never adopts them as a
different recording. When the only verified copy is unreachable, report that
state. Fallback requires a separately verified, currently authorized copy.
Restoring metadata cannot recreate missing frames.

Qualified storage must preserve acknowledged durable writes after loss of one
worker and its local disk, including publication and preservation records. Test
actual replica placement, attachment fencing and restore behavior. A successful
process restart, `fsync`, PVC name or StorageClass alone does not prove this.
Uncommitted media and capture downtime remain explicit gaps.

## Holds, exports and deletion

Core records authorized preservation intent for a source and time interval.
Pin whole intersecting blocks and their initialization dependencies when needed
to preserve that interval; doing so never widens playback authorization. A hold
has explicit pending, accepted and released outcomes. Core must not report it
accepted until the NVR durably acknowledges the pin for the exact copy/scope.
Missing or already deleted coverage is reported, not silently included in a
successful hold. Multi-block requests report unresolved coverage until every
required pin is acknowledged.

Core serializes pending holds against new retention grants. The NVR serializes
pins and deletion through the same durable disposition coordinator. For a delete
already in flight, the local durable boundary determines the result: a pin
committed first blocks deletion; a deletion committed first makes the affected
hold unavailable, never accepted. A lost pin acknowledgement conservatively
retains media and is reconciled using the same operation identity.

Release requires explicit authenticated authority and durable local release
acknowledgement. Lease expiry, disconnection, policy disablement and storage
pressure are not releases. Export preservation uses equivalent pins until the
export is verified and release is authorized. Pending or accepted protection
survives restart and blocks deletion until resolved; unknown state over-retains.

Deletion requires an explicit retention operation bound to the immutable copy,
current policy and disposition revision, with no conflicting preservation or
admitted read pin. Changed preservation state invalidates earlier deletion
permission. Persist a deletion intent/tombstone as the local commitment point
before unlinking. New reads and publication reject that state. Crash recovery
finishes the same operation and retains its terminal disposition; it does not
republish a leftover manifest. Shared dependencies remain until every dependent
recording permits their removal.

Retain disposition checkpoints/tombstones for the supported restore horizon.
Retries cannot reuse a stale revision after a hold, release or policy transition.
Authorized retention may intentionally remove the only local copy after all
preservation checks; requiring a second copy would silently require an archive
backend. Disk pressure alone never grants deletion authority. Read pins must be
bounded and coordinated with disposal; their protocol and deadlines belong to
tasks 1.8/3.7. Today's read-task concurrency limit is not a preservation pin.

## Required implementation evidence

Use synthetic media and execute the real publication/disposition interfaces.
These cases are acceptance requirements, not tests shipped by this document.

| Boundary exercised | Required observation |
| --- | --- |
| Seal without publication evidence | No advertised recording |
| Crash before/after each durable publication boundary; lost reply | Same exact operation reconciled, no duplicate logical block or premature availability |
| Reused operation ID with changed digest/storage UUID | Conflict; original evidence retained |
| New recorder attempts to freeze an unknown older block | Rejected; bytes preserved and unresolved |
| Reattach retained volume after qualified node/disk loss | Acknowledged media and records survive; routing changes, identity does not |
| Restore catalog with valid media and complete authority/history | Exact idempotent registration; fresh playback authorization still required |
| Restore older/missing hold or deletion history | No deletion or publication until history reconciles |
| Corrupt media, missing init or unrelated volume | Explicit unavailable interval; no fabricated coverage/fallback |
| Concurrent hold and deletion, including lost acknowledgements | One durable local outcome; no accepted hold whose bytes deletion may remove |
| Restart/partition after pending pin or explicit release | Conservative preservation and idempotent reconciliation; no implicit release |
| Retry deletion after preservation revision changes | Stale operation refused |
| Retention expiry without S3 | Authorized deletion succeeds only after preservation checks |
| Full media/control reserves | Bounded refusal/gap reporting; no unpersisted accepted operation or eviction of protected bytes |

Wire schemas, durable-record formats, database migrations, recovery checkpoint
retention limits and executable failure qualification remain implementation
work. They must satisfy these outcomes before local publication is enabled.
