# Historical recording block authority

`Camera.RecordingBlock` retains one allocated source/profile, recorder epoch and
block sequence. Reservation increments the claim counter and inserts the block
in the same transaction before local files are created. Failed file creation or
a crashed caller never reuses that allocation. The row captures ingest epoch,
relay and authenticated media ingress, the provisioned storage UUID and clock.
Later recorder acquisition does not replace these historical values.

The recording worker retains the native init hash, codec and timescale alongside
its spool state. After a local seal, it creates a receipt-free
`Camera.RecordingDescriptor` from the exact committed snapshot and freezes it
through `Camera.RecordingBlocks.freeze/5` before releasing the recorder claim.
The descriptor owns the same finite format limits as the archive manifest;
`Camera.RecordingManifest` adds object receipts to that shared semantic format.
Neither description verifies remote bytes or grants playback access.

Freeze locks ingest owner, recorder claim and then block. It compares descriptor
identity with the retained row, validates the original recorder, and rechecks
claim, ingest and persisted relay expiry using fresh database time before commit.
An identical retry returns the retained descriptor; a different descriptor fails.
The block's relative key depends only on source/profile, recorder epoch and
sequence, so changing clock or content cannot avoid an identity conflict.

Upload acquisition locks the frozen block independently. A fresh token and
monotonic upload epoch admit one worker; renewal, release and short CNPG work
require the original handle and a live database-time lease. Recorder release or
a new recorder generation does not invalidate this frozen historical authority.
Renewal inside a publication transaction cannot extend that transaction's
original deadline; crossing it rolls back both the renewal and publication.
Local lease deadlines must use request-start monotonic time plus the remaining
duration in the database receipt, as recorder admission already does. No external
I/O belongs inside either transaction fence.

This slice has only `open_local`, `sealed` and `uploading` states. An upload lease
does not mean any object exists. [Immutable destination binding](archive-binding.md)
retains a provisioning identity without enabling storage access. Object upload,
multipart reconciliation, archive verification and index availability remain
separate work. No credential reference or retention/deletion authority is added.

A local seal followed by a crash before database freeze remains unavailable for
upload. An expired recorder or its replacement cannot bless that journal. Safe
recovery needs an earlier fenced prefix commitment and proof that the local
writer cannot race any destructive recovery; this slice adds neither. It leaves
the bytes intact and never calls destructive recovery during takeover. Storage
loss before archival can still lose local footage.

The guarded database keepers cover allocation races and crashed callers,
identity/conflicting freeze rejection, independent upload claimants, stale
upload rejection and database-time rollback. The existing real synthetic media
worker keeper checks that freeze precedes recorder release. These database
bodies require the existing guarded CI database lane; compiling or selecting
them on RBE does not execute them.
