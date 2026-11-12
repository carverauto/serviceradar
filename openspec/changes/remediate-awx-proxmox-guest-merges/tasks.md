## 1. Implementation
- [x] 1.1 Judge each AWX merge audit row from the audit and both records' own identifiers, and
  every later merge of any reason on a record a bad merge poisoned (the chain rule), in pure
  planning code (`Decisions.awx_merge_evidence/1`, `Decisions.plan_awx_proxmox_unmerge/3`), with
  units and newest-first ordering.
- [x] 1.2 Add the explicit-only `awx-proxmox-unmerge` step: dry-run report of every action, gated
  execute, synced write-ahead manifest, one transaction per merge with a recheck under the locks,
  the unmerge by audit id and a distinct assertion per pair.
- [x] 1.3 Move the MAC rows copied from the wrong guest to the guest's own record, or archive them
  when no live record holds the guest (`Decisions.plan_awx_wrong_guest_macs/1`), and re-query
  them.
- [x] 1.4 Reverse the step through `source-id-rollback`.
- [x] 1.5 Add the read-only `awx-proxmox-verify` step.
- [x] 1.6 Unit tests for the planner; database tests for execute, the ambiguous case, chain
  ordering and units, a chained `hypervisor_guest_network_match` merge, MAC moves and archive only
  with proof, idempotent replay and rollback.
- [x] 1.7 Runbook `docs/awx-proxmox-unmerge-runbook.md`.

## 2. Operation (owner)
- [ ] 2.1 Dry run on the demo deployment and review every planned unmerge and MAC removal.
- [ ] 2.2 Execute with the runtime gate enabled, then disable the gate.
- [ ] 2.3 Run `awx-proxmox-verify` until it is settled, after later AWX and Proxmox syncs.
