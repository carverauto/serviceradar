# Change: Add structured hypervisor storage enrichment

## Why
Proxmox exposes storage, disk, and Ceph topology, while sysmon can collect deeper local ZFS facts when the ServiceRadar agent runs on a PVE host. Storing those details as provider metadata makes dashboard drilldowns and alert rules brittle, especially as vSphere/vCenter support arrives.

## What Changes
- Add provider-neutral storage pool, dataset, and vdev enrichment records that can be populated by Proxmox, sysmon ZFS collection, and future vSphere/vCenter adapters.
- Correlate sysmon ZFS observations with hypervisor hosts and Proxmox datastores using canonical `device_uid`, pool/dataset names, disk path, and disk by-id evidence.
- Surface structured storage health/capacity on hypervisor device details and the dashboard pressure drilldown.
- Make storage pool/dataset/vdev fields queryable by SRQL and available as alert rule inputs.

## Impact
- Affected specs: `device-inventory`, `sysmon-library`
- Affected code: `pkg/sysmon`, agent sysmon payloads, core migrations/resources/ingestors, Proxmox hypervisor ingestor, SRQL entity mapping, web-ng dashboard/device details, alert rule inputs
