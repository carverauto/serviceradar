# Local storage qualification and copy registration

## 1. Four different facts

| Fact | Owner and evidence | Meaning |
| --- | --- | --- |
| Intent accepted | Core's frozen block and immutable intent receipt | The original authority and content correlation agree |
| Storage qualified | Deployment qualification authority and retained evidence | This storage lifetime/configuration satisfies the selected failure profile |
| Copy registered | Core's distinct immutable local-copy operation | Verified, synced local evidence was registered against that authority |
| Copy currently readable | Current owner/read readiness and fresh authorization | This request may attempt a bounded read; the read must still verify bytes |

None of these facts implies the next. A registered copy may be unreachable or
corrupt. Its historical registration must survive those state changes without
being presented as current playback availability. NVR replicas never replicate
media; S3 is optional and is not proof of durability for unarchived local bytes.

## 2. Qualification belongs to the deployment

Introduce an immutable local-storage binding generation containing a binding
UUID, the existing storage UUID, a provider-resource reference and a canonical
configuration/profile digest. The profile identifies the provider/version,
replication/failure-domain policy, durability semantics, attachment fencing and
retained-volume lifecycle covered by the evidence. Pod names, ordinals and
addresses are routing data. They cannot identify or qualify stored content.

A provider-resource reference is an opaque identity validated by the provisioning
adapter, not a path supplied by a recorder. Keep detailed operational identifiers
and captured qualification artifacts private. Repository fixtures and example
reports must be independently synthetic.

Qualification reports are immutable, revisioned records bound to that generation
and profile digest. Core keeps a separate current activation/withdrawal pointer.
A report contains its evidence digest, qualification policy revision, issuing
principal, issuance/expiry times and individually recorded required outcomes.
Parsing it, hashing it, or receiving all `passed` values does not authenticate or
approve it.

Only an explicitly authorized deployment qualification principal can activate a
report after verifying its evidence. An authenticated recorder can submit content
proof, but cannot activate its own qualification. Derive principal and permitted
storage scope from trusted authentication/configuration, never request fields.
Use a purpose-separated infrastructure identity, not camera credentials or a
SaaS entitlement. The same authority must be available in an isolated on-prem
installation. Manual operator approval of evidence is allowed; an unattended
qualifier needs its own scoped identity and executable verification.

Activation requires evidence for all of these outcomes on the actual profile:

- Acknowledged media, initialization, journal and publication/control writes
  survive loss of any one worker and its local disk.
- Replica placement and healthy-replica policy satisfy that failure claim;
  process restart, same-node replicas and nominal replica count are insufficient.
- An isolated old writer cannot continue concurrently with a replacement writer;
  provider attachment fencing and application ownership are tested separately.
- Reattachment preserves the original storage UUID and exact committed bytes.
- Scale-down/deletion lifecycle retains the volume and unresolved data.
- Restore preserves the required publication, preservation and deletion history.

The policy must explicitly bound report validity and current health-observation
age. Missing policy, expired evidence, unknown health or withdrawn qualification
is ineligible for new registration. There is no default infinite lifetime or
implicit acceptance of a report because its provider is Longhorn/Ceph. Core
enforces freshness using its trusted time and policy bounds; a recorder-supplied
timestamp cannot extend validity. Operational telemetry still traverses
JetStream; qualification records contain bounded control-plane decisions and
evidence references, not a parallel telemetry store.
Numerical policy limits must be selected and tested before activation; this
proposal makes no throughput, rebuild-time or retention-horizon claim.

Changes to any bound provider resource, profile or failure-domain policy require
a new binding generation and qualification. Keep previous generations for
historical evidence. A new empty volume receives a new storage UUID even if its
PVC or StatefulSet ordinal is reused. Credential rotation alone need not change
content identity, but authentication must continue to bind the intended storage
lifetime.

## 3. Registration is a new operation

Keep `LocalPublicationIntent`, `publication.json`, `publication-ack.json` and the
v1 `intent_accepted` response unchanged. Add a distinct local-copy registration
operation and receipt; do not repurpose `RecordingBlock.archive_*` or S3 upload
receipts. The existing scheduler cannot infer or fabricate this new proof from
an accepted intent.

The immutable registration tuple contains:

- A new operation UUID and the accepted intent's operation UUID and SHA-256.
- Recording-block UUID, original storage UUID, block key and canonical descriptor
  SHA-256, matching the frozen authority and accepted intent.
- Exact storage-binding generation and qualification report/revision.
- The reconciled publication/preservation/disposition history checkpoint.

A current serving address, recorder process incarnation or user playback grant
is not part of this tuple. The trusted serving-owner registry can change a route
without changing the copy or granting authority to adopt another volume.

The NVR must verify all referenced media and initialization dependencies and sync
both content and its canonical registration record before sending it. The local
record and response have their own bounded formats and reserved control-space
allowances. Count their retained and in-flight bytes before admission; adding a
sidecar without updating inventory/reservations is not permitted. Unknown,
partial or conflicting records remain preserved and unresolved.

The authenticated request binds the submitting workload to the tuple's storage
UUID. Core verifies that the accepted intent and original frozen block match,
that the exact qualification is current and eligible, and that history is
consistent with no deletion commitment. These checks and insertion of the
immutable registration commit in one transaction. Serialize registration with
qualification withdrawal, history/disposition changes and competing operations;
use a consistent lock order. File reads, provider probes and network requests
must finish outside the transaction. The transaction checks stored, authenticated,
bounded-age evidence and its generation, not an unverified remote callback.

Core returns canonical `local_copy_registered` acknowledgement bytes only after
commit. They bind the operation UUID and SHA-256 of the complete canonical
registration record. The NVR validates that correlation and durably persists the
response before marking delivery complete. A lost response retries the original
operation and bytes. A different operation UUID for the same copy conflicts; callers must recover
and retry the original operation rather than create a second logical recording.

Exact retries of an already committed operation return its original receipt,
even if qualification or reachability has since changed. This is historical
idempotency, not renewed eligibility. Changed bytes under that operation UUID
conflict. New registrations require current eligibility and cannot reuse a
withdrawn qualification. Requalification creates explicit new evidence; it never
rewrites what a historical receipt proved. Current protection is resolved from
the active binding/qualification for the verified storage lifetime, not from the
report ID embedded in an old receipt. Requalification of the same retained
lifetime may restore protection after history reconciliation without replacing
its historical copy identity or registration.

## 4. Eligibility, withdrawal and restore

Keep these dimensions separate in storage and read APIs:

| Dimension | States / behavior |
| --- | --- |
| Publication | Unregistered, registered, or unresolved/conflicting evidence |
| Storage eligibility | Qualified/current, expired, withdrawn, degraded or unknown |
| Reachability | Current authorized owner route, unreachable, or unknown |
| Preservation/disposition | Reconciled checkpoint, unresolved history, or committed deletion |

Withdrawal immediately prevents new registrations and removes the claim of
current qualified protection. It does not erase registration history, delete
media, release holds or prove physical writer retirement. Capture admission and any finite offline grants must enforce their
own qualification/expiry rules; this proposal does not implement offline grants.
A transient route outage changes reachability without rewriting history.

Expiry or reduced replication health alone does not erase a historical copy's
readability. An existing registered copy may still serve independently verified,
authorized reads when its owner, integrity and preservation/history gates remain
valid; expose the changed protection state separately. Withdrawal that invalidates
storage identity, integrity, ownership or history prevents reads through those
gates until reconciled. In particular, a tolerated single-node failure must not
require a full replica rebuild before reading surviving verified footage unless
the qualified provider's read/fencing contract itself requires that wait.

On restore, reconcile the retained volume against authoritative Core history
before creating a registration or making an existing one eligible again. A
matching checksum, empty catalog, older database backup or accepted intent alone
is insufficient. An incomplete history checkpoint preserves bytes and refuses
publication/deletion. A deletion commitment prevents an old registration or
snapshot from resurrecting the copy.

For a newly provisioned empty lifetime, establish its initial history checkpoint
explicitly in both control-plane and volume state before capture. Do not apply
that bootstrap operation to an existing spool merely because no history file was
found. Existing retained spools need supported provenance-checked reconciliation.

Playback still requires fresh camera/recording/interval authorization, a current
verified owner route, bounded read admission/preservation pins, and verification
of the requested bytes. Registration does not grant a browser access to a path,
digest, entire recording, another interval or a caller-supplied destination.
Until those owners are implemented, the catalog must not advertise playable
availability. A qualified second copy is required for fallback; local-only
retention never requires a second copy merely to permit authorized expiry.

## 5. Implementation order and proof

1. Implement the storage binding/report/current-eligibility resources and trusted
   activation/withdrawal boundary. Leave every installation unqualified initially.
2. Implement history bootstrap/reconciliation and disposition interlocks, bounded
   registration codecs, sidecar accounting and restart discovery.
3. Implement Core's idempotent registration transaction and authenticated receiver,
   then NVR delivery and retry using the existing bounded worker infrastructure.
4. Add current serving-owner routing and authorized playback only under the
   separately approved playback/transport contracts.
5. Execute physical node/disk-loss and attachment-fencing qualification against
   the selected provider profile before enabling it for real recording.

| Failure / adversarial case | Required result |
| --- | --- |
| Recorder submits a fabricated passing report | No qualification activation or copy registration |
| Valid intent, unqualified or wrong storage lifetime | Intent remains accepted; copy registration refused |
| Qualification withdrawn concurrently with registration | One serialized decision; historical row is never current qualified-protection evidence after withdrawal |
| New registration uses expired health/report or changed profile | Refused without overwriting evidence |
| Qualification expires while a registered copy remains intact and reachable | No new registration or qualified-protection claim; independently authorized verified reads may continue |
| Crash before local record sync / before Core commit | No successful registration acknowledgement |
| Commit succeeds but response or local acknowledgement is lost | Exact retry returns and retains the same receipt |
| Same operation ID, different tuple or qualification revision | Conflict, preserving the first operation |
| Duplicate operations race for one immutable copy | One registration; identical operations return the same receipt, different operation IDs conflict |
| Acknowledged writes followed by worker and local-disk loss | Exact committed bytes and records survive on a qualified replacement |
| Old writer remains reachable during replacement attach | No concurrent write authority; unresolved retirement blocks conflicting activation |
| Catalog/volume restore omits or rolls back preservation history | No new registration, advertised playback or destructive operation |
| Missing initialization, corrupt media, unavailable owner or changed permission | Explicit unavailable/denied playback, no unrelated fallback |
| Control space exhausted during publication | Bounded refusal and preserved bytes; no success without durable records |

Database tests own transaction/idempotency and authorization decisions. Packaged
NVR tests own durable files, accounting, retry and restart. Provider qualification
owns physical failure claims; a green synthetic release test cannot replace it.
No implementation task is complete merely because this design is approved.
