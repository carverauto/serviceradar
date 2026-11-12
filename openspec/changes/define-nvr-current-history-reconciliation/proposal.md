# Change: Fence NVR history recovery before restoring recording authority

Status: approved by the product owner; implementation is incremental.

## Why

Core and NVR now retain matching bootstrap installation evidence. Those records
prove a historical installation, not that the current catalog contains every
later publication, hold or deletion. Comparing hashes detects a mismatch between
two copies, but cannot detect restoring both copies to the same older point.

Ordinary worker loss is already a storage-provider responsibility. Deliberate
CNPG point-in-time recovery and volume snapshot recovery need a distinct,
explicit admission gate before old history can be trusted again. This is a
recovery procedure requirement, not another media replication system.

## What Changes

- Keep ordinary restart and qualified exclusive volume reattachment automatic
  when authoritative history is available and consistent.
- Require supported snapshot/PITR recovery to close admission and establish a
  fresh recovery generation in deployment control state outside the restored
  CNPG and NVR backup set, before restored workloads can serve requests.
- Reconcile a bounded, ordered history of publication, preservation and
  disposition before reopening the affected storage lifetime. Matching old
  receipts, an empty catalog and a completed installation are insufficient.
- Keep the recovery gate closed when authority, retained history or the supported
  restore horizon cannot be established. Surviving bytes remain inspectable.
- Keep S3 optional and media replication entirely provider-owned. No new hosted
  service or media-copy process is introduced.

## Decision requested

Approve an explicit operator recovery procedure for CNPG/PVC restores, including
fresh deployment recovery state that must not be restored with those snapshots.
The existing installation bootstrap APIs remain offline and admission-blocking
until this protocol and its consumers are implemented and qualified.

## Scope and dependencies

This refines task 2.2 of
[local-copy registration](../define-nvr-local-copy-registration/tasks.md), under
the approved [publication and restore contract](../add-scalable-camera-recording-plane/local-publication.md).
Implementation begins with the NVR recovery-state consumer and deployment
configuration; Core history, reconciliation and the operator recovery command
remain pending. Numerical restore horizons and provider qualification remain
prerequisites to enabling recovery.
