# Change: Device source facts API

## Why

ServiceRadar compares switch-port and VLAN facts from every source that reports
them. It promotes a canonical value and records a disagreement when sources
differ (`add-canonical-device-facts-and-source-disagreement`). Today only the
sync pipeline can feed that machinery: built-in integrations and inventory
plugins.

A system outside ServiceRadar may know where an endpoint is attached, such as a
network management system, a NAC tool or a CMDB. It has no way to contribute
that knowledge. The scalar device-facts API (`PATCH /api/devices/:uid/metadata`)
reserves `switch_port_attachment` and accepts only scalar values, so such a
caller is rejected. A value written there would not take part in source
comparison anyway.

## What Changes

- Add `PUT /api/devices/:uid/source-facts/:fact_key` to report the caller's
  value for a platform fact key (`switch_port_attachment` or `vlan_uid`).
- Add `DELETE /api/devices/:uid/source-facts/:fact_key?source=<label>` to
  withdraw it.
- A reported value goes through the same parsing, normalization, per-source
  storage (`platform.device_source_facts`), promotion and disagreement detection
  as a fact from a sync update. Unlike the sync path, a value that cannot be read
  is rejected with a reason instead of being dropped.
- The caller names its source with a label. ServiceRadar records the source as
  `api:<label>`, so an API caller can never be mistaken for a built-in
  integration or plugin, or match one of their authority rows.
- The source instance is the caller (`user:<id>`), so callers cannot overwrite
  or withdraw each other's facts. Observation time is stamped by the server.
- Withdrawing a value that is the device's canonical value, when no present
  source still reports it, clears the canonical value. It is not left in place
  with nothing behind it.
- Add a new permission, `devices.source_facts.write`. The operator and admin
  roles get it by default. The device must also be visible to the caller
  (`devices.view`).
- Add a docs page for the API.

## Impact

- Affected specs: `source-fact-reconciliation`.
- Affected code:
  - `ServiceRadar.Inventory.Device`: two generic actions.
  - `ServiceRadar.Inventory.SourceFacts`: report validation.
  - `ServiceRadar.Inventory.SourceFacts.Reconciler`: report, withdraw and snapshot entry points.
  - `ServiceRadar.Inventory.SourceFacts.Reports`: a new module.
  - The RBAC catalog.
  - The web-ng router and a new API controller.
  - Docs.
- There is no migration. `device_source_facts` already stores any source and
  instance.
- **BREAKING**: none.

## Out of Scope

- Operator authority for API sources. There is no settings surface for them, so
  an API value wins only when it is the sole source or every source agrees.
- Expiry. A reported fact stays present until it is withdrawn or replaced.
- A batch endpoint.
