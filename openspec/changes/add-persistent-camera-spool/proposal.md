# Change: Install persistent camera spools per core replica

## Why

The merged bounded capture entry point runs on the current relay owner and
requires an already initialized persistent spool. Core currently uses a
Deployment, so replacing a pod gives no stable association with an individual
recording volume. One shared claim cannot supply independent private spools
across core replicas.

## What Changes

- Plan the approved opt-in core StatefulSet with one retained, exclusively mounted PVC
  per replica. The existing Deployment remains the default.
- Keep storage initialization separate from normal startup and capture
  enablement. Bind each volume lifetime to an explicitly provisioned UUID.
- Specify a controlled Deployment-to-StatefulSet migration and preservation on
  scale-down, rollback and uninstall.
- Scope the corresponding Cloud inventory, chart preflight and restore changes
  before hosted enablement. Cloud restore currently targets a Deployment.

The user approved the per-replica persistent-storage direction using an opt-in
StatefulSet. The single-core demo alternative was not selected. Runtime
member-identity selection is implemented in the first bounded pass; the
initializer, chart packaging and installation remain unimplemented. This is not
rollout authorization. Maintenance-window approval and deployment acceptance
remain open. Architecture approval neither qualifies a provider nor enables recording.

## Impact

- Affected specifications: camera-recording (new installation requirements).
- Product: core Helm workload/storage configuration, runtime storage identity
  selection, explicit provisioning entry point and operational runbook.
- Cloud: media inventory/preservation, runtime values/preflight and restore
  targeting in the separate serviceradar-control repository.
- Related work: [VMS plan](../add-vms-storage-playback-engine/README.md),
  [spool identity](../add-vms-storage-playback-engine/spool-lifetime.md) and
  [bounded capture](../add-vms-storage-playback-engine/capture-once.md).
- The first implementation pass changes runtime identity configuration only.
  Chart, database, credential, bucket and deployment state remain unchanged.
