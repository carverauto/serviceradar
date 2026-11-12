## 1. Implementation
- [x] 1.1 Require the declared address or a universally administered MAC overlap, without a universally administered MAC contradiction, before an AWX host binds a Proxmox guest, for a lone candidate too; bind none when several candidates qualify.
- [x] 1.2 Carry only a bound guest's universally administered MACs onto the AWX host.
- [x] 1.3 Exclude locally administered MACs from the AWX holder MAC lookup and the AWX address-match MAC overlap, keeping every MAC as a contradiction.
- [x] 1.4 Remove the unique node name and VMID arm from Proxmox enrichment's AWX candidate match.
- [x] 1.5 Add database tests: two clusters reusing a node name and VMID (lone and multiple candidates), same-cluster binding by address, binding by universally administered MAC, a locally administered MAC that binds nothing and corroborates nothing, and Proxmox enrichment not adopting an AWX record on node name and VMID. The refusal tests fail before the change.

- [x] 1.6 Describe the AWX inventory sync emission gate as skipping only hosts known by name alone, with no identity claim; keep emitting hosts that declare only a Proxmox guest reference or a locally administered MAC, and cover both at the inventory sync boundary.
- [x] 1.7 Read v3 node names through `IntegrationIdentity.proxmox_v3_node_name/1` instead of a split that was one component short; cover node, guest, child and kind-named-cluster references.

## 2. Follow-up (not in this change)
- [ ] 2.1 Plan the repair of records merged by the old rule, from `platform.merge_audit` and `platform.device_identifier_archive`, with the owner.
