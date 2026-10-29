# Design: Link an agent's host to its device by strong identity

## Context

An agent check-in goes `AgentHelloRequest` / `ControlStreamHello` -> agent gateway
(`AgentGatewayServer.device_attrs_from_request/3`) -> `AgentGatewaySync.ensure_device_for_agent/2`
-> `IdentityReconciler.resolve_device_id/2` -> `Resolver.do_resolve_device_id/2`. The Resolver
looks up the update's strong identifiers in `Ids.identifier_priority/0` order (agent_id,
armis_device_id, integration_id, netbox_device_id, hardware_serial, mac), considers every record
owning one of its globally-unique MACs, and merges a split through
`MergeEngine.merge_conflicting_devices/4`. With no match it mints the agent_id-seeded uid; it
never falls back to the address while a strong identifier is present, and it never reads the
hostname.

Before this change the agent's only MAC was the one owning its announced address
(`selectHostInterfaceMACs`). A host whose known record held another NIC's MAC, or no MAC at all,
was split.

## Goals / Non-Goals

- Goals: link an agent to its host's existing device by strong identity alone; never fuse
  same-named hosts that share no strong identifier; keep older cores and agents working; keep the
  formal model describing the code.
- Non-goals: a strong identifier for a hypervisor node that its API reports without a MAC (a
  follow-up, D11); changing the sweep's alias handling (#6107, D9).

## Decisions

### D1. The agent classifies; core decides identity

The agent reports every interface it has, with the operating system's classification, instead of
leaving interfaces out. Leaving out was the old safety mechanism, and it threw away the MACs that
link a host. Classification is a fact about the host; which facts are identity is a policy, and a
policy fix should not need an agent release.

Classification is defined once, in `go/pkg/hostinventory`, from sysfs (no privilege needed):

| Kind | Linux evidence |
| --- | --- |
| loopback | `IFF_LOOPBACK` (not reported) |
| bridge | `/sys/class/net/<if>/bridge` |
| bond | `/sys/class/net/<if>/bonding` |
| vlan | `uevent` `DEVTYPE=vlan` |
| virtual (tap) | `tun_flags` with `IFF_TAP` |
| tunnel | `tun_flags` without `IFF_TAP`, `DEVTYPE` wireguard/ipip/gre/sit/ip6tnl/geneve, or a tunnel `type` |
| physical | `/sys/class/net/<if>/device`, and no `device/physfn` (an SR-IOV VF is virtual) |
| virtual | anything else: veth, dummy, macvlan, ipvlan |

MAC provenance is `addr_assign_type` (0 permanent, 1 random, 2 inherited, 3 assigned). The
permanent MAC is the current MAC when provenance is permanent, or a bond member's
`bonding_slave/perm_hwaddr`, which bonding hides behind the bond's MAC.

Outside Linux the platform gives no permission-free kind or provenance, so the agent reports only
the loopback flag and up/down.

### D2. Eligibility: permanent, globally administered MACs of physical NICs

`HostInterfaces.eligible_macs/1` keeps the permanent MAC of every interface classified physical
when it is a valid, globally administered unicast MAC that is not reserved. When at least one
such MAC exists, only these inventory MACs count. Consequences:

- A bridge (`vmbr0`) inherits a port's MAC and counts through that port, never on its own, so the
  bridge adds no identity and cannot claim one a port does not have.
- A bond member counts by its own permanent MAC, not the bond's.
- A veth, tap, dummy or VF is never identity, even with a globally administered MAC: it is a
  guest's or a container's.
- A randomized or software-set MAC has no permanent MAC behind it and is never identity.
- A locally administered or reserved MAC is never identity.

A physical NIC that is administratively down still counts: its MAC is hardware identity whatever
its link state.

Decision: when the classified inventory yields no eligible physical/bond-member permanent MAC,
core falls back to legacy `host_macs`, just as for an absent or unclassified inventory. This
preserves identity for container and other veth-only agents whose announced interface has a
software-set, globally administered MAC. Both fallback paths reject locally administered,
multicast and reserved MACs. The fallback never supplements a nonempty eligible physical set,
so a hypervisor cannot claim its guests' tap/veth MACs.

### D3. Wire compatibility

`AgentHelloRequest.host_interfaces` (field 13) and `ControlStreamHello.host_interfaces`
(field 15) are new; `host_ip` and `host_macs` keep their numbers and meaning (the announced
interface's MAC). An older core reads `host_macs` and behaves as before; an older agent sends no
inventory and core falls back to `host_macs`. A current agent outside Linux sends an inventory no
interface of which is classified, and core falls back to `host_macs` too: an unclassified
inventory says nothing about which MACs are the host's.

### D4. Which identifiers link, in what order

1. `agent_id`: the agent's own device, as before.
2. Eligible MAC overlap: the device holding any of them. Records the agent's MACs name together
   are one host and converge through the Resolver's conflict merge, under every `MergeEngine`
   guard (distinct agents, source-authoritative conflict, cooldown, asserted-distinct).
3. Hardware serial or system UUID: core already ranks `hardware_serial` above `mac`. The agent
   reports neither in this change: the Linux agent runs unprivileged (`User=serviceradar`,
   `CAP_NET_RAW` only), and DMI `product_serial` and `product_uuid` are readable by root only.
   Reading them would need a permission the agent does not have today, so this change does not
   add it.
4. The agent's IP set: corroboration only (D5), never a link on its own.

### D5. Hostname and address are corroboration, recorded for review

The [agent host evidence contract](../../../docs/docs/dire-identity-model.md#agent-host-evidence)
owns the corroboration conditions and capture/record ordering. A same-named host at another
site, a re-imaged machine, a reused address and a cloned VM can all present hostname/address
agreement; it is review evidence rather than a safe automatic identity match.

### D6. Armis: an agent may link to and merge with an Armis-held record

User decision, 2026-10-28: "armis records and stuff learned about an endpoint through an agent
should be fine to merge together". An agent's eligible strong identifiers linking to, or merging
with, a record that holds or held an Armis id is intended behaviour: the merged device is the
same endpoint, and the northbound value follows the merged device.

The agent update carries no source-authoritative identifier, so
`Resolver.source_refusal/2` applies no refusal to it; that is unchanged. The source-authoritative
rule for an update that itself carries an Armis id is unchanged too. How the pushed value changes:

- Reach. Armis files the MACs it reports under `<partition>:armis:<source>`, and identifier lookups
  are partition-exact, so an agent's MAC never matches a MAC Armis reported. It matches a MAC in
  the default partition that discovery (the mapper, the census, an agent) registered on the Armis
  record, usually after an earlier cross-source merge.
- Linking onto the Armis record. `update_existing_device_for_agent` writes `is_available: true`,
  which goes to `device_availability_legacy`; a `legacy`-semantics source pushes that value (the
  custom field is pushed as `not is_available`), so an endpoint Armis reported down is pushed up
  while its agent checks in. Under `merged` semantics the check-in records `agent_liveness`
  self-report evidence (`capture_self_report`), which resolves the device available: an endpoint
  Armis alone reported, which had no resolved state and was withheld as `missing_availability`,
  is pushed available. A source pinned to one agent's availability is unaffected.
- Merging an Armis record with the agent's device. When the agent's MACs name the agent's device
  and an Armis record, the Resolver's conflict merge keeps the device holding the agent id (the
  highest-priority match); the Armis id, its archived rows and its source observations move to
  it. The population then pushes the agent's device's value for that Armis id. The legacy row is
  not carried over: the survivor's own is pushed.
- Withholding. The population withholds an id whose device's metadata disagrees with the source
  (`source_linkage_mismatch`, `metadata_identifier_disagreement`). A merge copies Armis metadata
  only into keys the survivor lacks, so a survivor already carrying another source's
  `sync_service_id` or a different `armis_device_id` withholds the id instead of pushing it.
- Two Armis ids never meet on one record: `SourceAuthorityGuard` still refuses that merge
  (`source_block`).

### D7. Split pairs: a strong-identifier merge rule, and review otherwise

The DIRE rule is that agreement never merges two existing devices. That stays. A pair this change
can heal is one that shares an eligible MAC once the agent reports its full inventory, and the
existing explicit rule merges it: the Resolver finds both records through the agent's MACs and
`MergeEngine.merge_conflicting_devices/4` merges them, audited in `merge_audit`, under every guard.
That rule is backed by a strong identifier, so it is not an agreement merge.

A pair that shares no strong identifier (an agent device and a hypervisor record holding only its
integration id) is never merged automatically. The review paths in D5 and D8 open a
de-duplication task when their evidence is present. An operator merges it, marks it distinct or
dismisses it. A dedicated de-duplication pass was
considered and rejected: it would need to decide what the agent's check-in already decides, with
less evidence.

### D8. Aliases follow the documented rule

When an agent that shares no strong identifier with an address holder resolves at the address,
the holder's confirmed alias of it is invalidated (`AliasGuard`, `mark_stale`) and recorded as an
`alias_invalidated` decision, which opens a de-duplication task. Keeping the alias was considered:
alias lookups run first, so sweeps and weak sightings of the address would keep going to the old
record and the agent's device would never see them.

### D9. Multi-address hosts and the sweep's alias handling (#6107)

The inventory's per-interface addresses are evidence at check-in (D5) and are not written as alias
rows or as device addresses. The agent's device keeps its announced address as its primary IP.
#6107 bounds which aliases the sweep targets and credits a failed probe of an alias last seen
outside its window to no device; neither reads the agent inventory, and this change writes no alias
the sweep would target. The two do not interact: an agent's other addresses are not swept as its
aliases unless another source records them, as before.

### D10. One interface classifier

`go/pkg/hostinventory` owns interface classification and the host-internal name prefixes used by
both the agent and sysmon. The distinct network-metric and host-address filtering
contracts are documented in [Sysmon Profiles](../../../docs/docs/sysmon-profiles.md#network-interface-filtering).
Identity flows only through the hellos, never through sysmon metrics.

### D11. Hypervisor nodes without a MAC

Proxmox's API reports no node NIC MAC (`/nodes/{node}/network` carries none; the plugin's
`nodeManagementMACs` reads a `hwaddr` field real nodes never return). A node with no SNMP therefore
has a record holding only its integration id, and an agent on it shares nothing with that record:
D7's review applies. A strong bridge, the node's TLS certificate fingerprint seen from both the
Proxmox API and the agent, is a separate follow-up.

### D12. Formal model

`AgentObserve` reports `{AgentOf[h]} \cup (MacsOf(h) \cap HwIds)`, the model's eligible MACs.
Three goal environments (`agent_known_host`, `agent_same_name`, `agent_on_armis`) check every goal
property; `resolution_vacuity_agent_links_known_host` and `resolution_vacuity_agent_on_source_record`
prove the goal links an agent to its known host and to an Armis record. Golden traces
listed in [the formal model README](../../../formal/dire/README.md) pin the code in both arrival
orders. Agent and mapper hostname spelling remains unmodeled; agent-bound holders use `HostOf`
for hostname refusal.
The corroboration decision is covered by the integration tests.

## Risks / Trade-offs

- A MAC cloned onto two hosts in one partition (a VM template that keeps its MAC) now links more
  readily, because the agent reports more MACs. Distinct agents still never merge; an agent and a
  record without one can. Partitions keep sites with overlapping hardware apart.
- An endpoint linked to an agent pushes the agent's availability northbound (D6), by decision.
- A Proxmox node with no SNMP stays split from its agent device until an operator merges the
  de-duplication task or the follow-up bridge lands.
- Isolation holds in both arrival orders. A new integration record cannot adopt an agent-bound
  address holder on hostname agreement: `agent_bound_holder` records the existing
  `hostname_agreement_not_identity` policy block and opens a de-duplication task. The refusal
  follows source-authoritative refusal, preserving its precedence. Mapper/MAC holders remain
  eligible for hostname adoption, allowing Proxmox records to acquire their discovered MACs.
- Agent-before-Proxmox hosts without a shared strong identifier now remain two devices and
  require operator de-duplication; hostname and address agreement cannot distinguish them from
  same-named hosts at different sites.

## Migration

No schema migration is required. See the
[agent host evidence contract](../../../docs/docs/dire-identity-model.md#agent-host-evidence)
for upgrade requirements and the conditions for linking or opening review tasks.
