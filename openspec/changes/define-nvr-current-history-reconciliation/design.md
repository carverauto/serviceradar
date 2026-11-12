# NVR current-history reconciliation

Status: approved; this does not qualify storage or grant runtime admission.

## 1. Two different recovery operations

| Operation | Required boundary |
| --- | --- |
| Process restart or replacement after worker/disk loss | Qualified storage preserves acknowledged bytes; retire the old writer, reattach exclusively, reconcile against current Core history |
| CNPG PITR, volume snapshot restore, or disaster recovery | Close admission before exposing restored state, establish a fresh recovery generation, then reconcile authoritative history |

The first operation does not rotate the deployment recovery generation or require
manual approval merely because a pod changed. The second is deliberate recovery,
not an ordinary restart. It is less frequent but can roll back a hold or resurrect
a deleted copy. Its added cost is a recovery command/runbook and a small deployment
control record; it is not application-managed media replication.

## 2. Recovery admission gate

Deployment control owns a fresh, unpredictable recovery generation and a closed
or ready state for the deployment, with per-storage reconciliation results.
This is infrastructure control state, not a camera credential. The supported
restore workflow must create it outside the CNPG/volume data being restored.
Use existing deployment management; do not introduce another network service.
Kubernetes and non-Kubernetes installations must both have an explicit adapter.

Before restoring either data store, the operator workflow closes the gate,
quiesces capture/publication/read/deletion work, and verifies retirement of
previous writers and authority-bearing processes. It generates a new recovery
generation before restored Core or NVR instances can accept traffic. Existing
grants cannot survive this boundary; merely changing an environment variable on
one replica is not sufficient.

Normal application startup may read this trusted state, but cannot create a
ready generation, infer it from restored rows, or silently reopen the gate.
Missing/unavailable control state, inconsistent generations among replicas, or
unknown retirement leaves affected admission closed. History receipts and future
admission grants bind the generation, but historical rows retain their original
identity and provenance.

The gate's backing configuration and recovery command must not be overwritten by
an ordinary GitOps rollback. If deployment control is also lost or restored,
re-establish a fresh closed generation through the disaster-recovery procedure.
The implementation must not claim to detect arbitrary out-of-band rollback of
every trust source. Such a restore is unsupported until that procedure runs.

The first implementation checkpoint uses an operator-owned ConfigMap for
Kubernetes and a deployment-managed file for standalone NVR. The process pins a
canonical generation UUID at boot and re-reads a bounded exact generation/state
record. The [runtime contract](../../../docs/nvr-runtime.md#deployment-recovery-gate)
defines the file format and propagation limits. NVR, Core recording new-work
admission, archive-authority challenge/application, archive publication/playback
and local-publication acceptance consume it; remaining recovery consumers, per-storage
completion and the recovery command remain pending.

## 3. Ordered authoritative history

Core owns a per-storage ordered history and current head for publication,
preservation and disposition. Each immutable operation binds its operation UUID,
storage UUID, preceding sequence/digest, operation kind and exact bounded payload.
The storage UUID and history identity survive changes in the serving pod and
recovery generation. An exact retry returns the original receipt; changed bytes
or a competing operation at the same sequence conflict.

Initial history has an explicit genesis bound to the existing preparation and
installation acknowledgement. Establish it only through the new-empty-volume
bootstrap protocol. Missing history in a retained spool is never a genesis request.
Do not add a generic append API that lets a recorder invent authoritative holds,
releases, deletions or publication permission.

Each domain owner advances history atomically with its authoritative change.
Use one documented lock order for storage history, qualification and copy state.
Registration, pending holds and deletion permissions serialize against that head.
Network and filesystem work remains outside the database transaction. Existing
v1 intent acceptance and S3 archive receipts retain their current meanings.

NVR retains the corresponding bounded local records and acknowledgements. A local
pin is acknowledged only after durable persistence; a deletion commitment is
durable before unlinking. Unknown or partial operations remain preserved and
block the affected transition. Byte/count reservations include both retained and
in-flight control records before admission. Compaction cannot discard evidence
needed by a supported restore or unresolved operation.

## 4. Reconciliation protocol

1. Authenticate the current recovery authority and storage lifetime. Verify the
   provider attachment and previous-writer retirement outside any DB transaction.
2. Freeze or pin a bounded comparison head in Core. Enumerate retained local
   operations with bounded pages, byte limits and resumable cursors. A cursor
   binds the storage identity, recovery generation and comparison head.
3. Compare canonical operation identities and bytes against authoritative Core
   history. Verify content/initialization dependencies separately. Local hashes
   alone cannot reconstruct missing authority.
4. Re-deliver exact known operations or acknowledgements where supported. An
   unknown tail, conflicting operation, missing tombstone or incomplete hold
   history preserves bytes and reports unresolved recovery. A deletion commitment
   prevents leftover media/manifests from becoming a registered copy again.
5. Persist the reconciled head on the volume, sync its required files and
   namespace, and report that exact evidence through the trusted recovery caller.
   Core commits completion only if the comparison head and recovery generation
   remain current. A changed head requires another bounded reconciliation pass.
6. Open only the storage lifetime whose completion was confirmed in the current
   generation. Restart or a lost reply retries the same operation; it does not
   manufacture a new history or reuse a historical ready decision.

The result is current history eligibility only. Storage qualification, current
ownership, capture authority, playback permission, integrity and read pins remain
independent gates. Expired qualification alone retains the approved distinction
between new registration and independently authorized reads of an existing copy.

## 5. Restore provenance and retention

The recovery authority must verify the supported control-plane recovery source
and the history interval it covers. It must establish that publication, pending
and accepted holds, releases, and deletion commitments are complete through the
required recovery point. Matching checkpoints in two old snapshots are not that
evidence. An unsupported or unknown backup interval remains unresolved even when
all available checksums agree.

Select explicit history retention and supported media-restore horizons before
enabling a provider profile. Core backups/history and local tombstones must cover
that horizon. Restoring an older snapshot does not reset retention or authorize
discarding missing history. Backup artifacts and qualification reports remain
private operational evidence; repository examples and tests are synthetic.

## 6. Implementation and proof

Implement the deployment gate first, then the Core history owner and its domain
transactions, then local journal/accounting and reconciliation, then admission
consumers. Do not open the current bootstrap barrier after implementing only one
layer. No automatic restore-detection heuristic is a substitute for the gate.

| Test boundary | Required observation |
| --- | --- |
| Ordinary restart/qualified exclusive reattachment | Same history and generation; no needless operator intervention |
| Core-only, volume-only, or coordinated old snapshot restore | Gate closed before traffic; old ready receipts cannot reopen it |
| Deployment control missing, stale on one replica, or itself restored | Admission remains closed until a fresh generation is established |
| Missing/older hold or deletion history, including matching old snapshots | No publication, advertised playback or deletion; bytes preserved |
| Lost completion reply or partial local record | Exact retry or unresolved state; no rewrite/adoption |
| History advances while comparison is in progress | Completion rejected against the old comparison head |
| Registration/hold/deletion compete | One serialized decision at the domain owner |
| Bounded backlog or control capacity exhausted | Explicit refusal; no discarded unresolved evidence |

Database tests own serialization and authorization. Packaged-release tests own
local persistence, accounting, bounds and restart behavior. Deployment/provider
tests own actual restore isolation, writer retirement and worker/disk-loss claims.
All three must pass before enabling the corresponding capability.
