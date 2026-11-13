## 1. Implementation
- [x] 1.1 Judge each AWX merge audit row from the audit and both records' own identifiers, and
  every later merge of any reason on a record a bad merge poisoned (the chain rule), in pure
  planning code (`Decisions.awx_merge_evidence/1`, `Decisions.plan_awx_proxmox_unmerge/3`), with
  units and newest-first ordering.
- [x] 1.2 Add the explicit-only `awx-proxmox-unmerge` step: dry-run report of every action, gated
  execute, synced write-ahead manifest, one transaction per unit with a recheck under the locks,
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
- [x] 1.8 End a bad merge's poison at its unmerge (path-tagged poison, judged at each merge's
  time), and void `tainted_evidence` on a guest identity the survivor established through a merge
  that stays, so correct merges after a repair are not judged bad.
- [x] 1.9 Account for every planned unit in execute: skip reasons `disposition_changed` and
  `unit_changed` with each merge's disposition now, a log line per skip, `units_not_run` after a
  halt, and `unit_accounting_failures` when the outcomes do not add up.

- [x] 1.10 Proxmox enrichment matches guest candidates on identifier rows, the current address and
  a row-backed AWX claim only; the display MAC column and metadata projections are not evidence.
- [x] 1.11 An unmerge removes the identity projections naming the other record's identifiers from
  both records and records them in the unmerge audit row (`dropped_projections`).
- [x] 1.12 The planner judges merges after the repair that join a record it restored to another
  record on the merged record's AWX host; A2/A3 report them.
- [x] 1.13 Database tests: a bad merge, the repair, and an enrichment pass that does not merge the
  restored record back while a same-machine record rejoins; a restored record carrying another
  guest's projections is not matched; the post-repair merge is planned and fails A2/A3.

## 2. Operation (owner)
- [ ] 2.1 Dry run on the demo deployment and review every planned unmerge and MAC removal.
- [ ] 2.2 Execute with the runtime gate enabled, then disable the gate.
- [ ] 2.3 Run `awx-proxmox-verify` until it is settled, after later AWX and Proxmox syncs.
