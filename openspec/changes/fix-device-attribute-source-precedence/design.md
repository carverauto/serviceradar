## Context

`ocsf_devices` holds one value per attribute. Sources differ in what they know:
SNMP (mapper) reports `sysName`, `sysDescr` and `sysObjectID`; the passive
census sees an IP and a MAC; hypervisor enrichment sees a node's address and
platform role; an automation inventory lists hosts; an OUI lookup names the
NIC registrant. Today the last write wins, except for `ip` (never-downgrade
address rank, #3905, which ties a global IPv6 with a private IPv4) and manual
`type` ownership.

## Decisions

1. Each single-valued attribute (`name`, `vendor_name`, `type`,
   `integration_type`, `management_device_id`, and the primary `ip` with its
   last-sighted time) stores its source and evidence strength alongside the
   value, so a recorded clear (an empty value with a
   recorded strength) is distinguishable from an unset value. Strength is assigned by the writer from the evidence it holds, not
   inferred later from the value.
2. Strength order for `name`, weakest first. Several sources may share a
   tier; the same-source tie-break (decision 6) decides between them:
   1. address fallback: the update has no hostname, so the name is the
      kept address when it is not link-local (the passive census and
      hypervisor enrichment both produce these); a link-local kept address
      gives no address-fallback name;
   2. passive census sighting with an observed hostname;
   3. a name reported by an automation inventory (such as AWX);
   4. SNMP `sysName` from the mapper;
   5. a name reported by a platform inventory (decision 13), such as the
      hypervisor or camera inventory.
   The `hostname` column is gated by the same tiers and is accepted or
   rejected together with `name` as one value, because plugin inputs prefer
   `hostname` over `name`. Both `HypervisorEnrichmentIngestor` paths, the
   repeating existing-device host and guest update and
   `placeholder_device_update` on the create path, carry the inventory
   record's name as the tier 5 name / hostname pair when the record has one;
   a `provider_ref` or an address is never that name, and an update with no
   record name is a tier 1 address fallback (none for a link-local address).
3. Strength order for `vendor_name`, weakest first:
   1. a name that names SNMP agent software (Net-SNMP and similar), from
      device, integration or metadata evidence;
   2. the IEEE OUI registrant of the MAC (`mac_vendor_source = "ieee_oui"`),
      always this tier whatever the registrant string, so a census `Ubiquiti
      Inc` never ties a recorded `sysObjectID` `Ubiquiti`;
   3. a hardware vendor name from device, integration or metadata evidence: a
      `sysObjectID` hardware enterprise, `sysDescr` inference, a
      classification rule, an integration report, or explicit metadata.
   For a value that is not an OUI lookup, the name, not the channel or the
   `sysObjectID` enterprise alone, decides whether it is agent software, a
   hardware vendor, or not a vendor.
   The agent-software enterprises are a fixed, named list kept next to the
   enterprise-to-vendor table, only to mark table entries whose name is agent
   software; the vendor name, not the enterprise number, decides the tier.
   A `sysObjectID` under enterprise 8072 with a hardware vendor from
   `sysDescr` or a classification rule is tier 3; a `sysDescr` or
   classification result that names agent software is tier 1.
   Not vendor evidence, and never written to `vendor_name` from any source: an
   OS, software or platform name (`Linux`, `Microsoft`, `NGINX`, `Apache`,
   `Caddy`, an automation platform's own product name, ...). OS and software
   names are written to the OS / software fields instead. A write whose
   vendor is not vendor evidence does not write `model` either (for example
   Proxmox discovery's `Proxmox` / `PVE`). Such a name is
   ignored for `vendor_name`; the same update's OUI or hardware vendor is
   still ranked normally.
   `model` is accepted or rejected together with `vendor_name` as one value,
   at the vendor's write strength, because the mapper `sysDescr`, the
   automation inventory and the hypervisor / UniFi sources all write it.
4. Strength order for `type`, weakest first:
   1. a generic type set without device evidence (`host` from an automation
      inventory, or a default);
   2. a type inferred from a passive fingerprint or classification rule;
   3. a type derived from SNMP (for example `Router` from `ip_forwarding`);
   4. a type reported by the inventory that owns the device's platform role
      (hypervisor inventory `Hypervisor` / `Virtual`), strictly above SNMP so
      a hypervisor node that routes VM traffic keeps `Hypervisor`.
   `type`, `type_id` and `metadata.device_role` are accepted or rejected
   together as one value, so a rejected `Router` cannot leave its `type_id`
   beside a kept `Hypervisor`, and a mapper role (`router`, `ap_bridge`,
   `switch_l2` or `host` from `role_for_metrics` / `persist_role_metadata`)
   never replaces a platform `hypervisor` / `virtual-guest` role. That keeps
   `PluginInputPayloadBuilder`'s `device_role` and `target_kind` and
   `ProxmoxHostAuthority`'s role read stable; `device_role` is still copied
   into plugin inputs. Manual `type` ownership keeps precedence over all
   four, for all three fields.
5. Strength order for `integration_type`, weakest first:
   1. a generic automation inventory that lists the device as a host;
   2. the inventory that discovers the device as its own platform object
      (hypervisor inventory for a hypervisor node or VM).
6. The stored source is recorded alongside the strength. A write replaces
   the recorded value when its strength is strictly greater, or when its
   strength is equal and it comes from the same source that recorded the
   stored value (the same-source tie-break). A write from a different source
   at the same tier keeps the stored value until a strictly stronger write
   arrives. Accepted trade-off: if the owning source is removed or stops
   reporting, its value stays until something strictly stronger writes. The
   address-fallback name still follows the device's kept non-link-local
   address, because it is the same source rewriting its own value. A weaker write fills the
   attribute only when no strength has been recorded; a recorded clear (an
   empty value with a recorded strength, such as a platform inventory's
   `nil` `management_device_id`) is a stored decision. Nothing else decides:
   there is no test comparing the stored name with the stored address. A
   populated value without a recorded strength (rows written before this
   change) is kept against a weakest-tier write; the next write of any tier
   above the weakest replaces it and records its strength. A missing strength is
   never treated as a recorded weak strength. So the first census pass after
   rollout may change an unrecorded spelling once (for example a legacy
   `Net-SNMP`, OS or hardware vendor spelling becomes the OUI spelling), and
   the first mapper pass may change it once more to a stronger value.
7. An address fallback name is derived from the address the device keeps after
   the address rank guard, never from an update address the guard rejected, so
   an NDP or link-local (`fe80::`) sighting cannot rename a device, and
   never from a link-local kept address: a link-local primary leaves the
   name and hostname at a stronger recorded value, or unset. A recorded
   address-fallback name follows the non-link-local address the device
   keeps. An
   address-fallback write sets `name` only and never writes `hostname`:
   a hostname is identity evidence (hostname-agreement adoption), so
   writing a bare address into it lets a different device later polled at
   that address merge into this record. A stored hostname is left as it is
   by an address-fallback write; the same source rewriting its own
   fallback `name` still moves it to the kept address.
8. The upsert compares strength with the stored row inside the `ON CONFLICT`
   update, the same place the `ip` rank guard lives, so concurrent writers
   cannot race a read-then-write in Elixir. The decision accepts or rejects
   the write as a whole for each multi-field value (`name` / `hostname`,
   `vendor_name` / `model`, `type` / `type_id` / `device_role`); a field of
   that value the write does not carry stays stored and is never cleared by
   the write, so a role-only mapper write keeps `type` / `type_id` and an
   OUI write without a model keeps the stored `model`.
9. In-batch merging (`merge_records_by_uid`) applies the same order and the
   same replace rule (decision 6) to the updates it combines, so two updates for
   one device in one batch resolve the same way as in two batches.
10. The denormalized metadata `integration_id` slot is dropped. Integration
    membership already lives per provider in `device_identifiers`; readers of
    the slot move to the provider-scoped identifier: plugin inputs and
    `ProxmoxHostAuthority.target_ids`, `IdentityProjections.binding_keys`
    (unmerge), `ArmisNorthboundPopulation`, and the `SourceIdentityDrift`
    repair reread. The `ResultProcessor` writer that copies a snapshot
    `integration_id` into update metadata stops, or writes the
    provider-scoped identifier instead. A per-provider key in
    metadata was considered and rejected as a second copy of
    `device_identifiers`.
11. `PluginInputPayloadBuilder.normalize_device_row` copies an integration
    identifier into a plugin input item only for the plugin whose provider
    owns it. Proxmox inputs read the hypervisor provider ref from
    `device_identifiers`, which only the hypervisor inventory writes, so
    `ProxmoxHostAuthority.target_ids` sees a stable id.

12. Every single-valued attribute read by plugin input building or agent
    configuration compilation has one owning writer or a rank. Owned
    metadata keys are replaced only by their owner; another ingestor may only
    fill an absent key.

    | Attribute | Readers | Rule |
    | --- | --- | --- |
    | `name` / `hostname` | SNMP compiler, plugin inputs | ranked (decision 2) |
    | `vendor_name` / `model` | credential-rule target queries, plugin inputs | ranked (decision 3), one value |
    | `type` / `type_id` / `metadata.device_role` | plugin inputs (`target_kind`), `ProxmoxHostAuthority` | ranked (decision 4), one value |
    | `integration_type` | plugin inputs, unmerge | ranked (decision 5) |
    | metadata `integration_id` | (dropped) | provider-scoped identifiers (decision 10) |
    | `ip` | SNMP compiler, sweep compiler, plugin inputs | kept unless strictly stronger (usable IPv4 over any IPv6; routable over a link-local primary; else higher rank within the same family) or absent from its recording source's sightings (decision 14) |
    | `hypervisor_provider_ref`, `proxmox_node`, `proxmox_cluster`, `hypervisor_guest_type`, `hypervisor_vmid`, `proxmox_base_url` | plugin inputs, `ProxmoxHostAuthority` | owner: hypervisor platform inventory |
    | `proxmox_candidate`, `proxmox_tls_sans_recorded`, `proxmox_tls_san_ips` | plugin inputs, `ProxmoxHostAuthority`, credential-rule target queries | owner: mapper Proxmox candidate probe |
    | `management_device_id` | SNMP compiler (polling host) | ranked: platform inventory (camera) > mapper; a platform clear to none is the stronger value and the mapper's empty-fill does not refill it |
    | tags / labels | target queries | merged maps (union), not single-valued |
    | `name` / `hostname` / `type` / `type_id` / `device_role` from `AgentGatewaySync` | - | non-writer: the agent check-in hostname and type are corroboration, not identity |
    | defaulted vendor (for example a WiFi-map batch filler when the row has none) | - | non-writer: not vendor evidence |

13. Any integration inventory that reports a device's identity is platform
    inventory for those fields, by default, so a new integration needs no new
    tier decision: its `name` / `hostname` take name tier 5, `vendor_name` /
    `model` the hardware-vendor tier, `type` / `type_id` / `device_role` the
    platform-inventory type tier, and `management_device_id` the platform
    tier above the mapper. The automation inventory (AWX) is the ranked
    exception: its name sits below SNMP `sysName`, its `host` type is the
    generic type, and its own platform product name is not vendor evidence.
    Every writer goes through the same strength decision (decision 8), with
    no direct Ash update that skips it. Known writers to route:
    `HypervisorEnrichmentIngestor`, `ProxmoxEnrichmentIngestor`,
    `Camera.InventoryIngestor` (`camera_device_update_attrs`, for example
    UniFi Protect), the WiFi-map controller and batch ingestion
    (`WifiMap.BatchIngestor`), and `EndpointInventoryIngestor`.
    `AgentGatewaySync` is not one of them: its check-in hostname and type
    are corroboration, and it no longer writes `name`, `hostname`, `type`,
    `type_id` or `device_role`. A defaulted or guessed vendor (such as
    `WifiMap.BatchIngestor`'s default when the row has none) is not vendor
    evidence and never writes `vendor_name`. Writers that share a tier are
    settled by the same-source tie-break (decision 6).

14. A usable IPv4 is always the preferred primary address. A routable address is an
    address the chooser accepts that is not link-local, not a directed
    broadcast (per `AliasPolicy.valid_alias_ip?/2` with the device's known
    CIDRs) and not host-internal; a ULA (rank 30) is routable. A usable IPv4
    is a routable IPv4 (`sr_address_rank >= 40`), and an IPv6-only device is
    one with no usable IPv4 (a `169.254/16` IPv4 does not count). Within a
    family the never-downgrade rank still holds, so a link-local never
    replaces a ULA or anything stronger. When a device has a usable IPv4, a usable IPv4 is the
    primary `ip`; no IPv6
    becomes primary on a dual-stack device, and every aliasable IPv6 (global
    or ULA, per `AliasPolicy.valid_alias_ip?/2` with the device's known
    CIDRs) is recorded as an alias.
    The preference only ranks addresses each chooser already accepts:
    `GuestAddress.primary/1` keeps skipping host-internal addresses such as
    a docker bridge, and the rule never promotes an address a chooser
    rejects. An IPv6 is primary only on an IPv6-only
    device; if that device later gains a usable IPv4, the usable IPv4 takes over.
    A stored primary is kept unless the incoming address is strictly
    stronger (a usable IPv4 over any IPv6; a routable address of either
    family over a link-local primary of either family, so a routable IPv6
    replaces a `169.254/16` primary; otherwise a higher rank within
    the same family after the existing IPv4-mapped unwrap, so
    `::ffff:a.b.c.d` is IPv4; a higher-rank IPv6 never replaces a usable
    IPv4) or the stored address is absent from the sightings of the source
    that recorded it (that source's full address set for the device, every
    address it reported for the device in the snapshot or window including
    candidates its chooser did not submit, no longer contains it, or it
    aged out of that source's window); a single-address update from another
    source never counts as absence. The recording source and last-sighted
    time of the primary are stored (decision 1); every source that feeds
    the primary passes its full per-device address set to the batch
    builder, and absence is computed from that set and window in the
    census / sync batch builder before the per-address write (a census snapshot is applied as a
    set per device) and passed to the upsert as an input. The upsert never
    infers absence from `EXCLUDED.ip` differing from the stored ip. Equal rank never replaces, matching
    `Identity.Address.better?/2`, for two usable IPv4s and for equal-rank
    link-locals (`fe80::` vs `169.254/16`) on a link-local-only device. A
    real re-IP replaces the primary once the old address leaves the
    recording source's window. The rule holds in every primary-IP chooser, including: the SQL
    upsert guard in `DeviceWrites`, `Identity.Address.best/1` and its rank
    (kept in step by the existing parity test, extended to the family rule),
    the hypervisor guest primary-IP NIC selection (`primary_ip_by_guest`),
    the hypervisor host selection (`primary_ip_by_host/1` with
    `primary_interface_ip`, `management_ip_score` and
    `routable_management_ip?`), the `DeviceDiscoveryIngestor` guest address
    fallback, the Proxmox plugin's `primaryIP` / `firstUsableIP`
    (`go/cmd/wasm-plugins/proxmox/summaries.go`, called from
    `discovery.go`), the Armis sync source's address walk in
    `filterDevices` (`go/pkg/agent/syncsources/armis/device.go`, called from
    `driver.go`; its candidate set is the union of the split `IPAddress`,
    `IPv4Addresses` and `IPv6Addresses`, ordered usable IPv4, then
    non-link-local IPv6, then a link-local only if nothing else, skipping
    blacklisted addresses; `primaryIP` is left alone), the NetBox plugin's `primaryIP`
    (`go/cmd/wasm-plugins/netbox/main.go`, which takes `primary_ip4` only
    when it is a usable IPv4, otherwise its routable IPv6, otherwise a
    link-local), the agent gateway check-in (`AgentGatewaySync`
    `update_existing_device_for_agent` and the `:gateway_restore` path,
    which today assign the check-in source ip directly and instead go
    through the same keep decision; the explicit contested-address release
    to `nil` stays), and the camera path. Each orders its candidates usable
    IPv4, then routable IPv6, then link-local only if nothing else; a
    link-local IPv4 (`169.254/16`) loses to any routable address of either
    family, so when the only IPv4 is link-local the routable IPv6 is
    submitted if one exists, and a device the source emits whose only
    addresses are link-local still submits one (never an empty primary that
    drops the device; Proxmox discovery's existing skip of guests with no
    routable address is unchanged). Each chooser and
    `Identity.Address.best/1` pick the highest-strength candidate (usable
    IPv4, then routable IPv6, then link-local, then higher rank within the
    family); only among candidates of equal class and equal rank do they
    tie-break deterministically, the stored primary first if present among
    them, then the lowest address, never across ranks, so a stored
    `10.1.0.5` (rank 40) yields to `203.0.113.5` (rank 50) and a stored ULA
    to a global IPv6 on an IPv6-only device. `best/1` takes the stored
    primary as an optional input used only for that tie-break. No chooser
    submits a
    link-local (`fe80::/10`, `169.254/16`) as primary when a routable
    address exists. The succession hand-over `MergeEngine.take_address?/2`
    only compares the successor's stored `ip` with the survivor's; it does
    not scan other addresses, never replaces a usable IPv4 with an IPv6,
    never replaces a routable address with a link-local, never replaces a
    stored link-local primary with an equal-rank link-local, and takes a
    link-local only when the survivor has no primary at all; otherwise it
    follows the same keep-unless-strictly-stronger rule. A device whose only address is link-local
    keeps it as its primary under the #3905 rank (the existing sync test
    "a device with only link-local addresses keeps one" stays), without an
    address-fallback name or hostname; any routable address replaces
    it. The address-fallback name (decision 7) follows this primary except
    that it is never a link-local; it never takes an IPv6 literal when the
    device has a usable IPv4, and an IPv6-only device's fallback name may be
    its routable IPv6.
15. Every aliasable address a device owns, in both families, stays a live `:ip` alias
    in `device_alias_states`, including an address displaced from primary or
    never promoted, so the sweep targets both families. Aliasable means
    `AliasPolicy.valid_alias_ip?/2`, called with the device's known
    interface CIDRs as `AliasEvents` and the mapper already do, accepts the
    address (it admits, among others, global, private and ULA addresses, and
    rejects link-local addresses and directed broadcasts, including a bare
    `192.0.2.255` on a known `192.0.2.0/24` interface; the class list is
    illustrative) and
    the address is not host-internal: not skipped by
    `GuestAddress.host_internal_address?/2`, not in the Proxmox plugin's
    host-internal set, and not a shared interface address that
    `AliasEvents` keeps off the `:ip` merge type. A host-internal address is
    neither primary nor alias, so a `172.17.0.1` reported by every container
    host cannot move between devices. Link-local addresses
    (`fe80::/10`, `169.254/16`) never become aliases or names, and are never
    primary on a device with a routable address; a
    shared link-local such as a vendor `fe80::1` would otherwise merge or
    flip between devices, consistent with the link-local alias archive
    migration. An address has one
    live holder per partition: on a confirmed re-attribution of an address
    to another device, the previous holder's alias for it is expired in the
    same write; holders that have not re-sighted an address within the alias
    expiry window are expired; `SweepCompiler` attributes a sweep target only
    to the current live holder.

## Open questions

- None that block implementation.

## Rejected alternatives

- Ignore `name` / `vendor_name` in the config version hash: the compiled config
  really does change (target name, credential), so the version must change.
- Drop the census's name and vendor entirely: loses enrichment for devices no
  other source describes, which the passive-census spec intends to keep.
- Treat a stored name equal to the stored address as replaceable: a second
  definition of "placeholder" that disagrees with the recorded strength. It
  lets a guard-rejected address rename a device, and classifies an observed
  `sysName` that happens to be an address as a placeholder, which restarts the
  loop this change exists to stop.
- Refuse any name that parses as an IP literal (an address-literal stop-gap):
  it hides the census and hypervisor-enrichment writes without ranking them,
  drops a real `sysName` that is an address, and leaves `vendor_name`, `type`
  and `integration_type` flipping. The name fix is built on recorded strength
  instead.
