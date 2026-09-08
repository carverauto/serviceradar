## Context
The Proxmox work added the first real virtualization enrichment path: host discovery, guests, guest NIC/IP identity, dashboard summaries, credential-brokered API access, and early console support. That work should finish as the first provider, but the shared platform concepts must not remain named or shaped around Proxmox. vSphere/vCenter support is expected soon and should not require another full ingestion, identity, UI, alerting, or console stack.

## Goals
- Treat Proxmox, vSphere/vCenter, and future platforms as hypervisor providers.
- Keep provider plugins as adapters that collect native API data and emit a shared envelope.
- Store common virtualization facts in provider-neutral tables/resources and reserve metadata for provider-only details.
- Share guest identity resolution by MAC, IP, hostname, and provider refs across providers.
- Share remote-console authorization, credential brokering, auditing, browser xterm UI, and web-ng to gateway to agent transport for hypervisors, SSH devices, and future protocols such as RDP.
- Let SRQL, dashboards, device details, and alert rules query generic virtualization fields first.

## Non-Goals
- Do not block the current Proxmox credential/discovery fixes on a large refactor.
- Do not remove provider-specific metadata when no generic field exists yet.
- Do not implement vSphere/vCenter in this change; prove readiness with a synthetic provider fixture and documented contract.

## Proposed Architecture
Hypervisor providers should produce a common envelope:

```json
{
  "schema": "serviceradar.hypervisor_enrichment.v1",
  "provider": "proxmox",
  "collector": {
    "agent_id": "agent-site-a",
    "plugin_id": "proxmox-inventory",
    "credential_rule_id": "..."
  },
  "scope": {
    "partition": "default",
    "provider_instance_ref": "proxmox:cluster-a"
  },
  "clusters": [],
  "hosts": [],
  "datastores": [],
  "storage_systems": [],
  "environmentals": [],
  "guests": [],
  "guest_network_interfaces": [],
  "guest_disks": [],
  "console_targets": []
}
```

Provider refs must be namespaced and stable: `<provider>:<provider_instance>:<kind>:<native_id>`. Native IDs remain in metadata for troubleshooting, but joins and idempotency use the namespaced provider ref.

### Hypervisor Adapter Contract

Provider adapters must translate native API objects into the shared envelope before persistence. The adapter boundary is intentionally narrow:

- Set one stable lowercase `provider` ID for every record, such as `proxmox`, `vsphere`, or `vcenter`.
- Emit provider refs for every durable object using `<provider>:<provider_instance>:<kind>:<native_id>`.
- Populate shared fields first: status, CPU, memory, disk, datastore, NIC, MAC, IP, bridge/VLAN, host refs, cluster refs, and observed timestamp.
- Put native API names, raw IDs, and provider-only values in `metadata`; never put credentials, tokens, tickets, passwords, private keys, or API authorization headers in metadata.
- Resolve relationships by provider refs in the envelope, not by display names.
- Emit guest MAC/IP evidence in `guest_network_interfaces` even when the provider cannot yet link the guest to an existing canonical device UID.
- Treat console targets as optional records that describe target identity and transport; they must not embed session tickets or credential material.

For vSphere/vCenter, the first adapter should map:

- Datacenter or vCenter inventory root to `scope.provider_instance_ref`.
- ClusterComputeResource to `clusters`.
- HostSystem to `hosts`.
- VirtualMachine to `guests`.
- Datastore and vSAN summaries to `datastores` and `storage_systems`.
- Physical NICs, VMkernel NICs, distributed port groups, and VM NICs to `network_interfaces`.
- VM guest agent or VMware Tools IP/MAC data to `guest_network_interfaces`.

Provider-specific gaps are acceptable at first, but downstream UI, SRQL, and alerting must consume the generic `virtualization_*` resources and only branch on `provider` for labels or native drilldowns.

## Identity Precedence

Hypervisor enrichment must never create a second identity algorithm per provider. Adapters normalize evidence, then shared ingestion resolves canonical devices in this order:

1. Existing `device_uid` if it is already a valid ServiceRadar UID and still maps to an active device.
2. Guest NIC MAC identifiers in the reported partition.
3. Guest NIC IP identifiers in the reported partition.
4. Host or guest display name and hostname candidates.
5. Provider-ref-only virtualization records with `device_uid` left unset until another discovery source provides matching identity evidence.

MAC/IP matches are stronger than display-name matches. Name matching is a convenience for already-imported inventory and must not override a MAC/IP match. Provider refs are durable join keys for virtualization records, not proof that a canonical network device exists.

## Core Boundaries
- `HypervisorIngestor` owns shared persistence for hosts, clusters, datastores, guests, NICs, disks, storage, environmentals, and remote-console target metadata.
- `HypervisorIdentityResolver` owns MAC/IP/hostname/provider-ref matching and returns canonical device UIDs.
- `ProxmoxAdapter` translates current Proxmox payloads into the shared envelope until the plugin emits the envelope directly.
- Future `VSphereAdapter` should only map vCenter objects into the same envelope.
- UI and SRQL modules should read from `virtualization_*` resources and only branch by provider for labels or provider-only drilldowns.

## Current Provider-Specific Paths

These paths are known migration points. They can keep compatibility wrappers while the first Proxmox provider stabilizes:

- Plugin collection: `go/cmd/wasm-plugins/proxmox/**` remains the first provider adapter.
- Legacy ingestion adapter: `ServiceRadar.Inventory.ProxmoxEnrichmentIngestor` maps Proxmox payloads into `HypervisorEnrichmentIngestor`.
- Shared ingestion: `ServiceRadar.Inventory.HypervisorEnrichmentIngestor` owns provider-neutral persistence and identity linking.
- Device/dashboard UI: web-ng device details and dashboard read `virtualization_*` resources and now only use provider names for labels.
- Credential materialization: network credential rules and plugin assignment materialization still have Proxmox helper names where they build Proxmox inventory or console broker grants.
- Console resource compatibility: `ServiceRadar.Edge.ProxmoxConsoleSession` and `/proxmox-console` routes remain active compatibility surfaces.
- Console target metadata: `ServiceRadar.Edge.RemoteConsoleTarget` is the generic target contract that Proxmox sessions now embed in metadata.
- Browser terminal compatibility: `ProxmoxConsoleLive`, `ProxmoxConsoleTerminal.js`, and Proxmox stream channel names still need generic remote-console wrappers before non-Proxmox SSH/RDP targets reuse the same UI path.

## Credential And Remote Console Model
Credential rules should be generic hypervisor rules with provider and purpose fields:

- `provider`: `proxmox`, `vsphere`, or future provider ID.
- `purpose`: `inventory_enrichment`, `console_access`, `ssh_access`, `rdp_access`, or future restricted operations.
- `scope`: explicit agent/site/SRQL scope, with auto-discovery trials disabled by default unless the operator opts in.

Credential purpose boundaries:

- `inventory_enrichment` grants read-only collection of host, guest, storage, network, and health data.
- `console_access` grants only the material needed to open a user-initiated console session to a selected target.
- `ssh_access` and `rdp_access` are direct device access purposes and should prefer browser-provided session credentials or ServiceRadar-issued short-lived certificates over centrally stored private keys.
- Future write purposes must be separate from inventory and console purposes, auditable, and disabled unless explicitly granted.

Agents receive credential broker grants only for rules whose provider, purpose, target scope, and agent/site scope match the assignment being materialized.

Remote-console sessions are not Proxmox-specific. The platform should provide a generic tunnel:

```text
browser xterm -> web-ng -> agent-gateway -> selected agent -> target network/device
```

The tunnel is what lets operators reach segmented, remote, and overlapping IP spaces from the agent that can actually see the target. Proxmox, SSH-to-device, and future RDP targets should all use the same session lifecycle, frame relay, RBAC, audit, and credential-broker path.

Console sessions should use generic target metadata:

```json
{
  "schema": "serviceradar.remote_console_target.v1",
  "provider": "proxmox",
  "target_ref": "proxmox:cluster-a:guest:100",
  "target_type": "guest",
  "protocol": "ssh",
  "transport": "pty",
  "credential_purpose": "console_access",
  "agent_uid": "agent-site-a",
  "capabilities": ["data", "resize", "close"]
}
```

Remote-console target metadata has these responsibilities:

- `schema`: identifies the target contract version.
- `provider`: the provider adapter, or `generic` for direct inventory-device protocols.
- `target_ref`: a provider ref when available, otherwise a stable canonical device ref.
- `target_type`: `device`, `host`, `guest`, or a future generic type.
- `protocol`: logical protocol such as `ssh`, `proxmox-termproxy`, `vnc`, or future `rdp`.
- `transport`: browser/broker stream shape such as `pty`, `framebuffer`, or future protocol-specific transports.
- `agent_id`: the selected edge agent that can reach the target.
- `capabilities`: stream operations supported by the target, for example `data`, `resize`, and `close`.
- `metadata`: non-secret display and routing hints such as hostname, IP, target kind, or console mode.

Provider adapters own protocol-specific details after the target metadata is selected. For example, Proxmox can turn `proxmox-termproxy` into native PVE API calls, while a generic SSH adapter can use a browser-supplied session key or a ServiceRadar-issued short-lived SSH certificate. The session lifecycle, RBAC, audit fields, credential-rule purpose, and web-ng to gateway to agent tunnel remain provider neutral.

For a normal network device SSH console, `provider` can be omitted or set to `generic`, `target_type` can be `device`, and the target ref should be the canonical device UID or device identifier. For Windows hosts, the same session model should later allow an `rdp` protocol adapter, even if the browser renderer differs from xterm.

The browser and core should not know whether the provider ultimately uses Proxmox SSH/termproxy/VNC, plain SSH to a device, vSphere console APIs, or future RDP. That belongs in the selected agent-side protocol/provider adapter. Console session creation, RBAC, audit records, credential broker grants, and frame relay stay generic.

## Migration Strategy
1. Finish the current Proxmox bugfix branch so operators can test the first provider.
2. Add the shared ingestor and adapter layer behind the current Proxmox behavior.
3. Move existing Proxmox ingestion into the adapter without changing schema output.
4. Extract Proxmox console code into a generic remote-console substrate with compatibility wrappers for active Proxmox routes and payloads.
5. Rename externally visible generic concepts where possible; keep compatibility wrappers for old internal names during migration.
6. Add a synthetic vSphere-shaped fixture before building the real vSphere plugin.
7. Use that fixture plus a generic SSH-console fixture as acceptance tests that duplicate provider pipelines are not creeping back in.

## Risks
- A broad rename could destabilize active Proxmox testing. Keep the refactor stacked after the current Proxmox fixes.
- Provider APIs expose different concepts for clusters, datastores, environmentals, and console transport. The envelope must tolerate missing fields and preserve provider metadata without making metadata the primary query path.
- Console access has higher security/audit requirements than inventory enrichment. Treat remote-console credential purpose and auditability as first-class generic fields, not provider-specific plugin settings.
- RDP is not xterm-compatible, so the remote-console substrate must separate session/control-plane lifecycle from the browser renderer and protocol adapter.
