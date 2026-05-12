## 1. Schema And Resources
- [ ] 1.1 Add platform-schema migrations for storage pools, datasets, and vdevs.
- [ ] 1.2 Add Ash resources and SRQL entity mappings for the new storage records.
- [ ] 1.3 Add uniqueness and lookup indexes for provider refs, host refs, device UID, pool name, dataset name, disk path, and disk by-id.

## 2. Collection And Ingestion
- [ ] 2.1 Extend sysmon ZFS output to emit normalized pool, dataset, and vdev records with health/capacity/error fields.
- [ ] 2.2 Extend the hypervisor enrichment envelope to accept structured storage pool/dataset/vdev records.
- [ ] 2.3 Map Proxmox datastores, host disks, and Ceph pools into the shared storage model where fields align.
- [ ] 2.4 Correlate sysmon ZFS records to hypervisor hosts using device UID, pool/dataset name, disk path, and disk by-id evidence.

## 3. UI, Alerts, And Tests
- [ ] 3.1 Show structured storage health/capacity on hypervisor device details.
- [ ] 3.2 Include storage pool/dataset/vdev pressure in the dashboard virtualization pressure drilldown.
- [ ] 3.3 Expose storage health/capacity fields as alert rule inputs.
- [ ] 3.4 Add DB-backed ingestion, SRQL, dashboard, and device-detail tests.
