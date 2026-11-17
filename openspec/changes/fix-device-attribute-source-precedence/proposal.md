# Change: Weaker inventory evidence must not overwrite stronger device attributes

## Why

Several discovery sources write the same single-valued device attributes, and
the sync upsert is last-writer-wins: `COALESCE(EXCLUDED.<field>, stored)`. A
source that knows less therefore erases what a better source recorded, and the
better source writes it back on its next pass. The attribute oscillates for as
long as both sources keep running.

Three oscillations were observed on one live deployment (values below are
synthetic stand-ins):

| Attribute | Stronger writer | Weaker writer | Flip |
| --- | --- | --- | --- |
| `name` | mapper (SNMP `sysName`: `ap-01`) | passive census (IP and MAC, no hostname) | `ap-01` <-> `192.0.2.20` |
| `vendor_name` | mapper (`sysDescr` inference: `Ubiquiti`) | passive census (IEEE OUI: `Ubiquiti Inc`) | every census pass |
| integration id on Proxmox nodes | Proxmox inventory plugin | AWX inventory plugin | every plugin run |

`DeviceRecords` builds `name: update.hostname || update.ip`, so a census update
with no hostname carries the bare IP as a name, and the upsert stores it over a
real name. `MacVendor` documents the OUI as a last-resort tier, but the tier is
only applied inside one update: an OUI guess still overwrites a vendor another
source reported earlier. The passive-census change already states the intended
rule (`add-passive-device-census`, "Passive observation is a weak identity
signal": hostname or vendor MAY be enriched *when absent or lower-confidence*);
the implementation does not enforce it.

### Why this is a config-churn bug, not only an inventory-quality bug

These attributes are inputs to agent config compilation:

- an SNMP query target is named `device.name || hostname || uid`;
- a credential rule's target query (for example `vendor_name:"<OUI org>"`)
  selects SNMPv3 for the matching devices and falls back to the profile's v2c
  credential otherwise, for SNMP profile targets and for mapper per-device
  credentials alike;
- policy-generated Proxmox plugin assignments embed each node's integration id
  in their `inputs`.

Every flip therefore re-versions the agent config. On the agent, a new SNMP
section restarted every collector (fixed separately in the agent), a new mapper
section restarted the discovery engine, which runs its scheduled job
immediately, and a new plugin assignment relaunched plugins mid-run. The mapper
run then writes `name` and `vendor_name` back, which re-versions the config
again. The loop is self-sustaining: one agent observed 18 SNMP restarts in 45
minutes, bursts of four config versions inside one second (one per rewritten
plugin assignment), and the same sequence of versions recurring 40 minutes
apart, which shows the compile output is a pure function of the flipping
inventory state rather than of nondeterministic compilation.

## What Changes

- A device attribute written by sync ingestion carries the strength of its
  evidence, and a write never replaces a stored value with weaker evidence:
  - `name`: an IP placeholder (`name` derived from the address because the
    update has no hostname) fills an empty name, or replaces a placeholder for
    the stored address, and never replaces an observed name.
  - `vendor_name`: an OUI-derived vendor (`metadata.mac_vendor_source =
    "ieee_oui"`) fills an empty vendor or replaces another OUI-derived vendor,
    and never replaces a vendor a source reported or inferred from device
    evidence. The OUI provenance keys follow the value that is kept.
  - The same rule applies inside one ingestion batch (`merge_records_by_uid`)
    as across batches (the upsert), so batch composition cannot change the
    outcome.
- Integration-scoped identifiers written by two integrations onto one device
  are kept per integration instead of in one last-writer-wins slot, so the AWX
  and Proxmox sources stop overwriting each other. (Design question: per-source
  map in metadata versus the existing identifier registry; see design.md.)
- No change to the agent config compilers. Masking the flapping fields there
  would hide the inventory defect and keep the wrong value in the UI.

## Operator impact (needs a decision before rollout)

Once `vendor_name` stops flipping it settles on the stronger value. A
credential rule written against the OUI spelling (`vendor_name:"<OUI org>"`)
then stops matching devices whose SNMP-derived vendor is spelled differently,
or whose SNMP agent reports a software vendor such as `Net-SNMP`. On the
deployment above, the devices that only answer SNMPv3 were polled successfully
only while the OUI spelling was stored. Release notes must call this out, and
such rules should select devices by a stable key (uid list, tag, or a
prefix match) instead of an exact vendor string. Whether an OUI vendor of a
burned-in MAC should outrank a generic SNMP software vendor such as `Net-SNMP`
is an open design question in design.md.

## Impact

- Affected specs: `device-inventory`
- Affected code: `ServiceRadar.Inventory.Sync.DeviceRecords`,
  `ServiceRadar.Inventory.Sync.DeviceWrites.device_upsert_update_query/0`,
  the integration-id writers for AWX and Proxmox inventory.
