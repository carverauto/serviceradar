## 1. Agent inventory
- [x] 1.1 `go/pkg/hostinventory`: enumerate interfaces, classify kind and MAC provenance from sysfs, read bond members' `perm_hwaddr`; flag-only classification outside Linux
- [x] 1.2 Move the host-internal interface name prefixes into `hostinventory` and use them for host IP selection
- [x] 1.3 `HostInterface`, `HostInterfaceKind`, `MacProvenance` in `proto/monitoring.proto`; `host_interfaces` on `AgentHelloRequest` (13) and `ControlStreamHello` (15); regenerate Go and Elixir bindings
- [x] 1.4 Both hellos report the inventory beside unchanged `host_ip` / `host_macs`
- [x] 1.5 Follow-up: move sysmon's interface walkers (`network.go`, `host.go`) onto `hostinventory`

## 2. Gateway and core
- [x] 2.1 The agent gateway forwards `host_interfaces` to `AgentGatewaySync`
- [x] 2.2 `HostInterfaces.eligible_macs/1`: permanent, globally administered MACs of physical NICs; `:unclassified` falls back to `host_macs`
- [x] 2.3 `AgentGatewaySync` resolves and registers the agent by its eligible MACs
- [x] 2.4 `AgentCorroboration`: address plus first hostname label recorded as `agent_corroboration_not_identity`, never acted on

## 3. Formal model
- [x] 3.1 `AgentObserve` reports only eligible MACs; document the user's Armis decision
- [x] 3.2 Goal configurations `agent_known_host`, `agent_same_name`, `agent_on_armis`; vacuity configurations for the known-host link and the Armis join
- [x] 3.3 Agent host identity golden traces, including reverse arrival order (see [trace inventory](../../../formal/dire/README.md))
- [x] 3.4 `formal/dire/README.md`: environments, traces, the old model/code divergence, what is not modeled

## 4. Tests
- [x] 4.1 Go: sysfs classification table; both hellos carry the classified inventory and the legacy fields
- [x] 4.2 Gateway: `host_interfaces` forwarded; hello wire format readable by older decoders and from older agents
- [x] 4.3 Core unit: eligibility (bridge, bond, veth, tap, randomized, locally administered, unclassified)
- [x] 4.4 Core integration: short and FQDN agents link through a NIC they do not announce; same-named hosts at two sites never fuse; an agent sharing no strong identifier takes nothing; Armis link and merge northbound values

## 5. Docs and follow-ups
- [x] 5.1 `docs/docs/dire-identity-model.md` agent host evidence
- [ ] 5.2 Follow-up issue: hypervisor node TLS certificate fingerprint as a strong identifier
