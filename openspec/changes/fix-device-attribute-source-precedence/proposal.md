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

The primary address also flips on dual-stack devices. The upsert's
never-downgrade guard (the `ip` CASE in `DeviceWrites`) compares
`LEAST(sr_address_rank(new), 40) >= LEAST(sr_address_rank(old), 40)`, so a
global IPv6 (rank 50) ties any usable IPv4 (private rank 40 or global rank 50)
and the last writer wins. The passive census decoder writes `ip` = the observation address for
every sighting, so an NDP sighting makes the IPv6 primary and another writer
puts the IPv4 back; one device went `2001:db8::3` -> `192.0.2.3` ->
`2001:db8::3` -> `192.0.2.3` within two minutes. While the IPv6 is primary,
the device's own IPv4 has no live `device_alias_states` row, so
`SweepCompiler` drops it: the ICMP sparkline gaps and one agent's config
re-versioned about 42 times per hour. Stale cross-device alias rows also make
the sweep target `device_uid` attribution flip on each compile.

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
  `vendor_name`, `type`, `integration_type`, `management_device_id`) records
  its source and evidence strength alongside the value, so a recorded clear
  is distinguishable from an unset value. A write replaces the recorded value when its
  strength is strictly greater, or equal and from the same source that
  recorded it; a different source at the same tier keeps the stored value. A
  weaker write fills the attribute only when no strength has been recorded,
  so a recorded clear stays. A populated value with no recorded strength (written before
  rollout) may be replaced once by a write of any tier above the weakest, which
  records its strength, and never by a weakest-tier write. There is no second
  test (such as "the stored name equals the stored address"): the recorded
  strength alone decides.
  - `name`, weakest to strongest (sources sharing a tier are settled by the
    same-source rule): address
    fallback (the update has no hostname, so the name is an address, as from
    the passive census or a hypervisor-enrichment update whose record has no
    name) < passive census sighting with an observed hostname < automation
    inventory (AWX) name < SNMP `sysName` < platform inventory name (such
    as the hypervisor or camera inventory; the repeating
    hypervisor-enrichment update for an existing host or guest carries it
    from the inventory record). `hostname` is gated by
    the same tiers and decided together with `name` as one value, so plugin
    inputs, which prefer `hostname`, stop flipping. An address fallback is
    the address the device keeps after the existing address rank guard,
    never an address the guard rejected and never a link-local, so an NDP
    or link-local (`fe80::`) sighting never renames a device and a
    link-local-only device keeps a stronger recorded name, or none.
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
    inventory). `type`, `type_id` and `metadata.device_role` are accepted or
    rejected together, manual ownership included, so a mapper `host` /
    `router` role no longer replaces a `hypervisor` role and flips the
    Proxmox plugin item's `target_kind`. `model` is decided together with
    `vendor_name`. `integration_type` follows the tiers in design.md. The
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
- Every single-valued attribute read by plugin inputs or config
  compilation has one owning writer or a rank (design.md decision 12): the
  Proxmox metadata keys have one owner and other ingestors only fill them
  when absent, and a platform inventory's `management_device_id` (such as
  the camera inventory's) outranks the mapper's, including a clear to none
  that the mapper's empty-fill must not undo.
- Any integration inventory that reports a device's identity is platform
  inventory for those fields by default (top name tier, hardware-vendor
  tier, platform type tier), with the automation inventory as the ranked
  exception. Every such writer (hypervisor and Proxmox enrichment, camera
  inventory, WiFi-map ingestion, endpoint inventory) goes through the same
  strength decision, with no bypassing update. The agent gateway check-in's
  hostname and type are corroboration and no longer write identity fields,
  and a defaulted vendor (such as a WiFi-map batch filler) never writes
  `vendor_name`. A write
  decides a multi-field value as a whole, and a field it does not carry
  stays stored.
- A usable IPv4 is always the preferred primary address. A routable address is one
  the chooser accepts that is not link-local, a directed broadcast or
  host-internal (a ULA is routable); a usable IPv4 is a routable IPv4
  (`sr_address_rank >= 40`); an IPv6-only device has no usable IPv4 (a
  `169.254/16` address does not count). Within a family the never-downgrade
  rank still holds, so a link-local never replaces a ULA. When a device has a usable IPv4,
  a usable IPv4 is its primary `ip`; no IPv6 becomes primary
  on a dual-stack device, and every aliasable IPv6 (global or ULA, as
  `AliasPolicy.valid_alias_ip?/2` defines with the device's known CIDRs) is
  recorded as an alias. The rule
  only ranks addresses a chooser already accepts, so it never promotes one
  the chooser rejects (for example a host-internal docker bridge address
  that `GuestAddress.primary/1` skips). An IPv6 is primary only on an
  IPv6-only device, and a usable IPv4 it later gains takes over (a
  `169.254/16` address does not). A stored primary is kept unless the
  incoming address is strictly stronger (a usable IPv4 over any IPv6; a
  routable address of either family over a link-local primary, so a routable
  IPv6 replaces a `169.254/16` primary; else a higher rank within the same
  family; a higher-rank IPv6 never replaces a
  usable IPv4) or the stored address is absent from the sightings of the
  source that recorded it, computed from that source's full per-device
  address set (every address it reported for the device, not only the one a
  chooser submitted) before the write and recorded with the primary's
  source; a single-address
  update from another source never counts as absence, and equal rank never
  replaces (two usable IPv4s, or `fe80::` vs `169.254/16` on a link-local-only
  device). A real re-IP replaces once the old address leaves the recording
  source's window. Every primary-IP chooser follows this rule,
  including the SQL upsert guard, `Identity.Address.best/1` and its rank
  (kept in step by the existing parity test), the hypervisor guest and host
  primary-IP selection (`primary_ip_by_guest`, `primary_ip_by_host/1`), the
  discovery ingestor's guest address fallback, the Proxmox plugin's
  `primaryIP` / `firstUsableIP`, the Armis sync source's address walk in
  `filterDevices` (over its split `IPAddress`, `IPv4Addresses` and
  `IPv6Addresses`), the NetBox plugin's `primaryIP` (its `primary_ip4` only
  when it is a usable IPv4), the agent gateway check-in (which no longer
  assigns its source ip directly), and the camera path; each orders usable IPv4,
  then routable IPv6, then link-local only if nothing else, so a device
  whose only addresses are link-local still submits one; the
  highest-strength candidate wins (class, then rank within the family), and
  only among equal-class equal-rank candidates does the stored primary come
  first, then the lowest address, never across ranks; none submits a
  link-local as primary when a routable address exists. The
  succession hand-over `MergeEngine.take_address?/2` compares only the two
  stored addresses, never replaces a usable IPv4 with an IPv6 or a routable
  address with a link-local or a link-local with an equal-rank link-local,
  and takes a link-local only when the survivor has no primary at all. A link-local-only device keeps its link-local primary under
  the #3905 rank, without an address-fallback name.
- Every aliasable address a device owns, in both families, stays a live
  alias, so the sweep targets both families. Aliasable means
  `AliasPolicy.valid_alias_ip?/2`, with the device's known CIDRs, accepts it
  (global, private and ULA, among others; link-local and directed
  broadcasts, including a bare broadcast on a known subnet, are rejected)
  and it is not
  host-internal (a container bridge a chooser skips, or a shared interface
  address); host-internal addresses are neither primary nor alias.
  Link-local addresses (`fe80::/10`, `169.254/16`) never become aliases or
  names, and are never primary on a device with any routable address, matching `AliasPolicy` and the link-local alias archive. An address has one live holder per partition: a
  confirmed re-attribution expires the previous holder's alias in the same
  write, holders that have not re-sighted an address within the alias expiry
  window are expired, and sweep target attribution reads only the current
  live holder. The address-fallback name follows the primary `ip` except
  that it is never a link-local; it never takes an IPv6 literal when the
  device has a usable IPv4, and an IPv6-only device's fallback name may be
  its routable IPv6.
- No change to the agent config compilers. Masking the flapping fields there
  would hide the inventory defect and keep the wrong value in the UI.

## Operator impact

Once `vendor_name` stops flipping it settles on the strongest vendor evidence.
For a device with a recorded hardware vendor, the settled spelling is the one
from the first source recorded at the hardware tier: either the SNMP-derived
vendor (a hardware `sysObjectID` enterprise, or a hardware vendor from
`sysDescr` or a classification rule even when the `sysObjectID` is under a
generic agent-software enterprise such as Net-SNMP 8072) or a platform
inventory's vendor (such as the camera inventory's), whichever was recorded
first; the same-source tie-break keeps it. A credential rule written against
the OUI spelling (`vendor_name:"<OUI org>"`) then stops matching any device
with a recorded hardware vendor whose spelling differs, and the rule's SNMPv3 credential no longer applies; the
profile's v2c credential is used instead. On the deployment above, the devices
that only answer SNMPv3 were polled successfully only while the OUI spelling
was stored. Every device with no recorded hardware-tier vendor keeps its OUI
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
rollout once, to the OUI vendor; the first hardware-tier writer after it,
SNMP or a platform inventory, then becomes the owner of the vendor spelling.
Each attribute (name / hostname, `vendor_name` / `model`, `type` / `type_id`
/ `device_role`, `integration_type`, `management_device_id` including a
recorded clear) changes at most once per
strictly stronger tier first recorded, then stays constant: a name stored
before rollout may move to a census hostname, then an automation-inventory
name, then the mapper `sysName`, and on a hypervisor node finally to the
hypervisor platform inventory name, which is the final name there rather than
the `sysName`. A hostname-less census name is the address fallback, the
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
  `ServiceRadar.Core`; for the primary address and aliases, the census
  decoder (`Inventory.Discovery.Decoders.Census`),
  `ServiceRadar.Inventory.Identity.Address`, `ServiceRadar.Identity.DeviceAliasState`
  and `ServiceRadar.AgentConfig.Compilers.SweepCompiler`.
