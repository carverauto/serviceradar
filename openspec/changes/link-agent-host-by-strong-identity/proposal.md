# Change: Link an agent's host to its device by strong identity

## Why

When an agent enrolls on a host that another source already knows (a hypervisor inventory,
mapper/SNMP discovery, the sweep), it has to resolve to that same device. Today it often does
not, and the reason is not the hostname.

- The agent reports one MAC: the MAC of the interface that owns its announced address
  (`go/pkg/agent/host_identity.go`, `selectHostInterfaceMACs`). It leaves out every other NIC on
  purpose, so that a bridge, a guest's veth or another namespace's interface is never claimed.
  When the record that knows the host holds a MAC of a different NIC, the agent shares nothing
  with it and gets a new device.
- Core resolves the agent through `Resolver.do_resolve_device_id/2` on `agent_id`, then on every
  MAC it is given. It never uses the hostname, so a short name and an FQDN behaved the same; the
  split was the missing MAC.
- The formal model has always had the agent report every MAC of its device (`AgentObserve`
  reports `MacsOf(h)`), and the trace harness sent every MAC too. The model described an agent
  that did not exist, a divergence at the Go boundary the traces could not see.
- A hypervisor inventory gives a node no MAC: Proxmox `GET /nodes/{node}/network` returns no
  hardware address (pve-common `PVE::Network::Interfaces` stores none, and `PVE::API2::Network`
  adds none). A node record holding only its integration id shares nothing with any agent.

Same-named hosts at different sites are common and must never fuse, so the fix cannot be a
looser name or address match. It has to be more strong identity.

## What Changes

- The agent reports its whole host interface inventory at enrollment and on the control-stream
  hello: for every interface but loopback, its name, current MAC, permanent MAC when the platform
  reports one, every IP (v4 and v6), operational state, kind (physical, bond, bridge, VLAN,
  virtual, tunnel) and MAC provenance (`addr_assign_type`). The classification lives in one
  shared Go package, `go/pkg/hostinventory`. `host_ip` and `host_macs` keep their meaning, so a
  core that predates the inventory behaves as before.
- Core decides MAC eligibility and legacy fallback according to the
  [agent host evidence contract](../../../docs/docs/dire-identity-model.md#agent-host-evidence).
- A shared eligible MAC links the agent to the device that holds it, whatever its hostname or
  address. Two records the agent's MACs both name converge through the existing conflict merge.
- The agent's addresses and the first label of its hostname are corroboration only. Agreement
  with another device that shares no eligible MAC is recorded for review, as a `policy_block`
  decision with reason `agent_corroboration_not_identity`, and opens a de-duplication task. It
  never links or merges.
- An agent may link to, and merge with, a record holding or having held an Armis id (user
  decision, 2026-10-28). The northbound value then follows the merged device.
- The DIRE formal model's agent reports only eligible MACs, and gains goal, vacuity and trace
  coverage of an agent on a known host, same-named hosts at two sites, and an agent on an Armis
  device.

## Impact

- Affected specs: `device-identity-reconciliation`, `dire-formal-model`.
- Affected code: `proto/monitoring.proto` (`HostInterface`, `AgentHelloRequest.host_interfaces`,
  `ControlStreamHello.host_interfaces`), `go/pkg/hostinventory`, `go/pkg/agent/host_identity.go`,
  `go/pkg/sysmon`, the agent gateway's hello bridge, `ServiceRadar.Edge.AgentGatewaySync`,
  `ServiceRadar.Inventory.Identity.HostInterfaces`, `ServiceRadar.Inventory.Identity.AgentCorroboration`,
  `formal/dire`.
- Armis northbound: an agent linked to an Armis endpoint makes that endpoint's pushed availability
  follow the merged device (design D6).
- Not in this change: a strong identifier for a hypervisor node that has no MAC from its API
  (the TLS certificate fingerprint follow-up) and the sweep alias handling of #6107.
