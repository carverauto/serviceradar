# Change: Install persistent camera spools per core replica

## Why

The merged bounded capture entry point runs on the current relay owner and
requires an already initialized persistent spool. Core currently uses a
Deployment, so replacing a pod gives no stable association with an individual
recording volume. One shared claim cannot supply independent private spools
across core replicas.

## What Changes

- Propose an opt-in core StatefulSet with one retained, exclusively mounted PVC
  per replica. The existing Deployment remains the default.
- Keep storage initialization separate from normal startup and capture
  enablement. Bind each volume lifetime to an explicitly provisioned UUID.
- Specify a controlled Deployment-to-StatefulSet migration and preservation on
  scale-down, rollback and uninstall.
- Scope the corresponding Cloud inventory, chart preflight and restore changes
  before hosted enablement. Cloud restore currently targets a Deployment.

This is a proposal, not an implemented installation or rollout authorization.
The multi-replica option is recommended and awaits the operator's storage
choice. A single-core demo with one claim remains an alternative; selecting
that alternative requires updating this proposal before implementation.
Neither choice qualifies a provider or enables recording.

## Impact

- Affected specifications: camera-recording (new installation requirements).
- Product: core Helm workload/storage configuration, runtime storage identity
  selection, explicit provisioning entry point and operational runbook.
- Cloud: media inventory/preservation, runtime values/preflight and restore
  targeting in the separate serviceradar-control repository.
- Related work: [VMS plan](../add-vms-storage-playback-engine/README.md),
  [spool identity](../add-vms-storage-playback-engine/spool-lifetime.md) and
  [bounded capture](../add-vms-storage-playback-engine/capture-once.md).
- No application, chart, database, credential, bucket or deployment change is
  included in this planning change.

