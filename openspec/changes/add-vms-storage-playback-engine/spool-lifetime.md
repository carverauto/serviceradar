# Provisioned local spool identity

The recorder must verify that its configured storage UUID belongs to the mounted
spool before acquiring recorder authority or writing a block. The UUID still
follows the storage lifetime, not the pod, node, process or recorder epoch.
This checkpoint supplies local misbinding detection. Cloud remains responsible
for the actual volume/UUID association and preservation before replacement.

## Provision once, verify during use

Infrastructure explicitly calls
`ServiceRadarCoreElx.CameraRecording.Storage.initialize(root, storage_uuid)`
while it owns the volume exclusively, before starting recording. This is a
release-callable provisioning function, not a recorder startup hook. The caller
creates the root first with private permissions. The initializer never creates
the directory, changes its permissions, scans for/adopts recordings, or enables
recording.

An unmarked root must be empty. The initializer exclusively creates
`.storage-id`, sets mode `0600`, writes exactly the canonical lowercase UUID
followed by one newline (37 bytes), and fsyncs the file and root directory.
The existing `SERVICERADAR_CAMERA_RECORDING_STORAGE_ID` configuration must name
that UUID. There is no generated default or hostname fallback.

An exact retry verifies and syncs the existing marker and directory without
rewriting the marker, even if recording blocks now exist. A concurrent attempt
that sees an incomplete marker fails; retry after the original operation finishes
can verify the exact value. Missing, partial, malformed, oversized, conflicting,
nonregular or nonprivate markers are never repaired or replaced. An unmarked
nonempty root remains intact for explicit operator reconciliation. An initializer
error can leave a partial marker; preserving it is intentional.

`Storage.open/2` is read-only. It requires a real private root directory and a
real private regular marker; neither entry may be a symlink. It verifies the
exact configured UUID, bounds the marker read, and captures the filesystem's
device/inode identifiers for both entries. `Storage.verify/1` checks those
identifiers, permissions and bytes again. Missing or changed storage never
falls back to another directory or UUID.

## Recording and recovery boundaries

The worker opens storage before resolving/attaching its managed recording
pipeline, and verifies again before acquiring the recorder lease, reserving a
block and attaching. Lease renewal and progress receipts also require a current
match. Packaging retains its existing bounded in-memory behavior; it does not
perform filesystem validation for every encoded access unit.

`Spool.create` requires a verified handle. Create, append and seal verify before
and after filesystem mutations; a detected change cannot produce a new committed
receipt. Existing snapshots retain the handle, so subsequent init/fragment reads
also refuse a changed root. The portable descriptor, journal identity, archive
keys and manifest digest are unchanged: the local handle is never serialized
into the archive contract.

Recovery receives an explicit verified storage handle and the expected block
identity. It requires a real block directory directly under that root (no child symlink),
requires `init.mp4`, `media.m4s` and `journal` to be regular files with one hard
link each before reading any of them, and checks storage before each tail
truncation and after recovery. Symlinks and shared hard links cannot borrow
another block's files for recovery. Refusal preserves both blocks and their
incomplete tails. Recovery never initializes a marker. The
existing exclusive-recovery requirement remains: this API does not acquire
ownership, adopt a predecessor's block or make concurrent takeover safe.

After a process restart, open a new handle against the same configured UUID,
then recover with the original expected block identity under exclusive ownership.
No device/inode value is persisted as a cross-host identifier. Replacing storage
requires a new provisioned UUID; rescheduling the same volume retains its UUID.

These checks observe filesystem state at operation boundaries. They are not an
atomic operating-system mount lock, physical-volume attestation, or protection
against a privileged host that copies/changes a marker during I/O. A detected
change after filesystem I/O can leave bytes requiring reconciliation, but
returns no new spool receipt. A copied matching marker after restart cannot
prove the original physical volume. Cloud must establish that association
separately.

A successful `RecordingBlocks.freeze/5` result is the historical receipt. The
worker does not apply a later local usability check that turns that committed
row into a missing stopped snapshot. The stopped snapshot is retained only when
that freeze result is known, including when the marker is replaced across the
freeze return on the end-of-stream seal and the finite-capacity stop. A locally
sealed spool without a successful freeze is not a receipt. Current init and
fragment reads still verify the retained handle and refuse the replaced marker.
An upload lease of the frozen descriptor is not proof those bytes are still
readable.

## Owning proof and remaining work

`SpoolTest` owns actual-filesystem initialization/retry, marker schema/privacy,
root/marker substitution, unchanged error evidence and restart recovery.
`RecordingWorkerIntegrationTest` owns startup refusal before persisted recorder
authority, rejection during real synthetic media delivery without freezing a
block or interrupting a viewer, and marker replacement across a successful
freeze on the end-of-stream and finite-capacity paths. The frozen row remains
the historical receipt; current reads refuse the replaced marker. Published-head
readiness still requires `integration_tests_serial_4` to run all eight
synthetic cases, plus the full selected Core and Web database lifecycles,
including cleanup and fixture-generation lease release. That execution is not
deployed-camera validation. Existing media, RTSP, browser, manifest-byte and
lifecycle assertions remain required.

This supplies part of tasks 1.4/1.7, not complete recovery or hosted readiness.
Production recording remains disabled. This marker contract adds no database
resource, provider request, scheduler, upload authority, provisioning workflow
or local reclamation. Bounded media transport is the separate
[media upload](media-upload.md) checkpoint. Work still open after these two
checkpoints is tracked in the [handoff](README.md).

## Source validation

Measured results, negative controls and the guarded-database gate are recorded
in [validation](validation.md).
