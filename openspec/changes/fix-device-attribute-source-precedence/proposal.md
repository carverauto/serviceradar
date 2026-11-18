# Change: Weaker inventory evidence must not overwrite stronger device attributes

## Why

Several discovery sources write the same single-valued device attributes, and
the sync upsert is last-writer-wins: `COALESCE(EXCLUDED.<field>, stored)`. A
source that knows less therefore erases what a better source recorded, and the
better source writes it back on its next pass. The attribute oscillates for as
long as both sources keep running.

Several oscillations were observed on one live deployment (values below are
synthetic stand-ins):

| Attribute | Stronger writer | Weaker writer | Flip |
| --- | --- | --- | --- |
| `name` | mapper (SNMP `sysName`: `ap-01`) | passive census (IP and MAC, no hostname) | `ap-01` <-> `192.0.2.20` |
| `name` | automation inventory (node name: `hv-node-01`) | hypervisor enrichment (no hostname) | `hv-node-01` <-> `192.0.2.30` |
| `vendor_name` | mapper (SNMP `sysObjectID` enterprise: `Ubiquiti`) | passive census (IEEE OUI: `Ubiquiti Inc`) | every census pass |
| `type` | hypervisor enrichment (`Hypervisor` / `Virtual`) | automation inventory (`host`) | every inventory cycle |
| `integration_type` | hypervisor enrichment (`hypervisor`) | automation inventory (`awx`) | every inventory cycle |
| metadata `integration_id` on hypervisor nodes | hypervisor inventory | automation inventory | every inventory cycle |

Two producers send updates with no hostname:

- the netprobe passive census re-emits every binding it has seen in the last
  15 minutes on a 120 s snapshot, so a weak write for each known device
  arrives every 2 minutes;
- hypervisor enrichment (`HypervisorEnrichmentIngestor` updates to existing
  devices) carries the node's address but no hostname, so hypervisor node
  names flip between the node name and its address against the automation
  inventory.

Neither producer builds the row itself: core does. `DeviceRecords` builds
`name: update.hostname || update.ip` and adds the OUI vendor, so a
hostname-less update carries the bare IP as a name, and the upsert stores it
over a real name. `MacVendor` documents the OUI as a last-resort tier, but the
tier is only applied inside one update: an OUI guess still overwrites a vendor
another source reported earlier. The passive-census change already states the
intended rule (`add-passive-device-census`, "Passive observation is a weak
identity signal": hostname or vendor MAY be enriched *when absent or
lower-confidence*); the implementation does not enforce it.

Two writers also put values in `vendor_name` that are not vendor evidence at
all: passive fingerprint classification rules set OS or software product
names (for example `Linux`, `Microsoft`, `NGINX`, `Apache`, `Caddy`), and an
automation inventory reports its own platform product name as the vendor of
every host it manages.

Integration membership is already multi-valued in `device_identifiers`. Only
the denormalized metadata `integration_id` slot is single-valued: the upsert
merges `stored || EXCLUDED`, and both the automation inventory and hypervisor
enrichment re-send it every cycle, so the last writer wins.

### Why this is a config-churn bug, not only an inventory-quality bug

These attributes are inputs to agent config compilation:

- an SNMP query target is named `device.name || hostname || uid`;
- a credential rule's target query (for example `vendor_name:"<OUI org>"`)
  selects SNMPv3 for the matching devices and falls back to the profile's v2c
  credential otherwise, for SNMP profile targets and for mapper per-device
  credentials alike;
- `PluginInputPayloadBuilder.normalize_device_row` copies metadata
  `integration_id`, the vendor and `hostname || name` into every
  device-backed plugin input item, and policy-generated Proxmox plugin
  assignments embed those items in their `inputs`. The plugin consumer of
  `integration_id` is `ProxmoxHostAuthority.target_ids`; the slot is also read
  by `IdentityProjections.binding_keys` (unmerge), `ArmisNorthboundPopulation`
  and the `SourceIdentityDrift` repair reread, and `ResultProcessor` copies a
  snapshot `integration_id` into update metadata.

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

- Each single-valued attribute written by sync ingestion (`name`,
  `vendor_name`, `type`, `integration_type`) records its source and evidence
  strength alongside the value. An equal-or-stronger write replaces the
  recorded value; a weaker write fills the attribute only when it has no
  stored value. A populated value with no recorded strength (written before
  rollout) may be replaced once by a write of any tier above the weakest, which
  records its strength, and never by a weakest-tier write. There is no second
  test (such as "the stored name equals the stored address"): the recorded
  strength alone decides.
  - `name`, weakest to strongest, no two sources sharing a tier: address
    fallback (the update has no hostname, so the name is an address, as from
    the passive census or hypervisor enrichment) < passive census sighting
    with an observed hostname < automation inventory (AWX) name < SNMP
    `sysName` < hypervisor platform inventory name. `hostname` is gated by the
    same tiers and decided together with `name` as one value, so plugin
    inputs, which prefer `hostname`, stop flipping. An address fallback is the address the device keeps after
    the existing address rank guard, never an address the guard rejected, so
    an NDP or link-local (`fe80::`) sighting never renames a device.
  - `vendor_name`, weakest to strongest: a name that names SNMP agent
    software such as Net-SNMP (device, integration or metadata evidence) <
    IEEE OUI registrant (`metadata.mac_vendor_source = "ieee_oui"`), always
    this tier whatever the registrant string < a hardware vendor name
    (device, integration or metadata evidence: `sysObjectID` hardware
    enterprise, `sysDescr`, a classification rule including under enterprise
    8072, an integration report, or explicit metadata). For a value that is
    not an OUI lookup, the name rather than the channel or enterprise alone
    decides agent software, hardware vendor, or not a vendor. The OUI
    provenance keys follow the value that is kept.
  - Not vendor evidence, and never written to `vendor_name` from any source:
    an OS, software or platform name (`Linux`, `NGINX`, an automation
    platform's own product name, ...); OS and software names belong in the
    OS / software fields. The same update's OUI or hardware vendor is still
    ranked.
  - `type`, weakest to strongest: generic `host` < passive fingerprint type <
    SNMP-derived type (for example `Router` from `ip_forwarding`) <
    platform-inventory type (for example `Hypervisor` from the hypervisor
    inventory). `type` and `type_id` are accepted or rejected together,
    manual ownership included. `integration_type` follows the tiers in
    design.md. The
    automation inventory's generic `host` / `awx` no longer replaces the
    hypervisor inventory's `Hypervisor` / `Virtual` / `hypervisor`, and a
    mapper `Router` no longer replaces `Hypervisor` on a node that routes VM
    traffic.
  - The same rule applies inside one ingestion batch (`merge_records_by_uid`)
    as across batches (the upsert), so batch composition cannot change the
    outcome.
- The metadata `integration_id` slot is dropped in favour of the
  provider-scoped identifiers already in `device_identifiers`, so no
  integration overwrites another's id.
- Proxmox plugin inputs read the hypervisor provider ref from
  `device_identifiers` (a single writer), and `integration_id` is no longer
  copied into input items for plugins that do not own it.
- No change to the agent config compilers. Masking the flapping fields there
  would hide the inventory defect and keep the wrong value in the UI.

## Operator impact

Once `vendor_name` stops flipping it settles on the strongest vendor evidence.
For a device whose SNMP evidence derives a hardware vendor (a hardware
`sysObjectID` enterprise, or a hardware vendor from `sysDescr` or a
classification rule even when the `sysObjectID` is under a generic
agent-software enterprise such as Net-SNMP 8072), that is the SNMP-derived
vendor. A credential rule written against the OUI spelling
(`vendor_name:"<OUI org>"`) then stops matching such a device when the SNMP
spelling differs, and the rule's SNMPv3 credential no longer applies; the
profile's v2c credential is used instead. On the deployment above, the devices
that only answer SNMPv3 were polled successfully only while the OUI spelling
was stored. Every device that does not derive a hardware vendor keeps its OUI
vendor, including a device whose only vendor evidence is the OUI and a device
whose other evidence names agent software (for example Net-SNMP) or an OS,
software or platform; rules keyed on the OUI spelling keep matching it.
Fingerprint OS and software names no longer appear in `vendor_name`; rules
keyed on them (for example `vendor_name:"Linux"`) must move to the OS /
software fields.

On rows written before rollout, the first census pass replaces a stored
agent-software, OS or software vendor with no recorded strength by the OUI
vendor, so exact-OUI credential rules match that device again after that
pass. That first census pass may also change any other vendor stored before
rollout once, to the OUI vendor, and a name stored before rollout once, to a
census name that carries an observed hostname, until the mapper records a
stronger value. A hostname-less census name is the address fallback, the
weakest tier, and never replaces a populated name without recorded strength
or any stronger name.

Release notes must call this out, and such rules should select devices by a
stable key (uid list, tag, or a prefix match) instead of an exact vendor
string.

## Impact

- Affected specs: `device-inventory`
- Affected code: `ServiceRadar.Inventory.Sync.DeviceRecords`,
  `ServiceRadar.Inventory.Sync.DeviceWrites.device_upsert_update_query/0`,
  `ServiceRadar.Inventory.HypervisorEnrichmentIngestor`, the vendor inference
  in sync enrichment and the fingerprint classification rules, the
  automation-inventory and hypervisor integration writers,
  `ServiceRadar.Plugins.PluginInputPayloadBuilder`,
  `ServiceRadar.Plugins.ProxmoxHostAuthority`, and the other readers and
  writer of metadata `integration_id`:
  `ServiceRadar.Inventory.Identity.IdentityProjections`,
  `ServiceRadar.Integrations.ArmisNorthboundPopulation`,
  `ServiceRadar.Inventory.SourceIdentityDrift`, and the result processor in
  `ServiceRadar.Core`.
