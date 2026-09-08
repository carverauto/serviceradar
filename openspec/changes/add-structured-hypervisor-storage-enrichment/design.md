## Context
Proxmox API enrichment can report node storage, disks, and Ceph health. Sysmon already has or is expected to have host-local ZFS inspection, and agents will soon run directly on PVE hosts through Ansible. These sources describe overlapping storage objects at different layers:

- Proxmox datastores and Ceph pools describe hypervisor-visible capacity and attachment.
- Sysmon ZFS pools/datasets/vdevs describe host-local health, fragmentation, allocation, mountpoints, and backing devices.
- Future vSphere/vCenter providers will report datastores and backing storage through different native names.

The durable query model should not depend on provider-specific JSON metadata for common storage facts.

## Goals
- Store common storage facts in structured provider-neutral tables/resources.
- Correlate hypervisor and sysmon observations when they describe the same PVE host storage.
- Preserve provider-native metadata only for fields that do not map to shared storage concepts.
- Make storage pressure, health, and degradation usable by dashboard drilldowns, device details, SRQL, and alerts.

## Non-Goals
- Replacing the current Proxmox datastore and disk records in one migration step.
- Requiring the ServiceRadar agent to run on every PVE before Proxmox enrichment is useful.
- Modeling every ZFS property as a first-class column. Rare or provider-only fields may remain metadata.

## Data Model
Add or extend provider-neutral inventory resources for:

- `virtualization_storage_pools`: provider, provider_ref, host_provider_ref, cluster_provider_ref, device_uid, name, pool_type, health, status, used_bytes, free_bytes, total_bytes, allocation_ratio, fragmentation_percent, dedup_ratio, observed_at, metadata.
- `virtualization_storage_datasets`: provider, provider_ref, pool_provider_ref, host_provider_ref, device_uid, name, mountpoint, used_bytes, available_bytes, referenced_bytes, quota_bytes, reservation_bytes, compression_ratio, observed_at, metadata.
- `virtualization_storage_vdevs`: provider, provider_ref, pool_provider_ref, host_provider_ref, device_uid, path, by_id, disk_provider_ref, vdev_type, health, size_bytes, read_errors, write_errors, checksum_errors, observed_at, metadata.

Existing datastores remain the hypervisor-facing storage abstraction. Storage pools/datasets/vdevs add the local/backing detail that can be joined to datastores when evidence is available.

## Correlation
Correlation uses evidence in this order:

1. Canonical hypervisor host `device_uid`.
2. Exact provider refs when a provider reports them.
3. ZFS pool/dataset names matching Proxmox datastore names or storage metadata.
4. Disk path/by-id evidence matching host disk records.
5. Mountpoint evidence only as supporting context, not as a sole identity claim.

Sysmon must not claim or reclassify devices. It may enrich storage records for the canonical host device it is already running on.

## Alerting And UI
Dashboard pressure sources and device details should read structured storage records first. Alert rules should support storage pool health, pool capacity, dataset capacity, vdev health, and vdev error counters without parsing metadata JSON.
