# Change: Bind AWX hosts to Proxmox guests only on machine evidence

## Why
An AWX host imported from a Proxmox dynamic inventory carries the guest's Proxmox node name
and VMID, and nothing that says which Proxmox cluster it came from. Proxmox clusters reuse
both: every cluster has a first node with a stock name, and VMIDs start at 100 in each one.

Inventory ingestion looked guests up by VMID across every cluster, kept the candidates whose
node name agreed (a missing name on either side also counted), and bound a lone candidate with
no network evidence at all. The AWX host then took the guest's MACs, and the AWX reconciliation
merged the guest's device, the device holding those MACs and the AWX record into one. In a
deployment with two such clusters an AWX host of one cluster merged with the guest of the other,
and the survivor, now holding several machines' MACs, corroborated further merges on every sync.

Locally administered MACs made it worse. The AWX holder lookup and the AWX address match
treated any shared MAC as a match, including the fixed veth MAC a CNI gives every Kubernetes
node, against "Randomized MACs Are Evidence Only".

Proxmox enrichment had the same assumption in the other direction: it let a guest adopt an
existing AWX record whose node name and VMID matched when that pair was unique within the
result, with no address or MAC evidence.

## What Changes
- A Proxmox node name and VMID only narrow the guests an AWX host can bind to. Binding needs
  the guest to report the address the AWX host declares, or a shared universally administered
  MAC, with no universally administered MAC contradicting it. A lone candidate is held to the
  same rule; more than one candidate with evidence binds none.
- An unbound AWX host stays its own record. It takes no guest MACs and is not merged with
  reason `awx_proxmox_network_match`.
- A bound guest contributes only its universally administered MACs to the AWX host.
- A locally administered MAC neither finds an AWX holder by MAC nor counts as a MAC overlap at
  an address. Any MAC can still contradict a match.
- Proxmox enrichment no longer lets a guest adopt an AWX record on a unique node name and VMID:
  the guest must report the AWX host's declared address or an address of the AWX record.
- The AWX plugin's inventory sync no longer calls a Proxmox node name and VMID an identity anchor.
  Its emission gate is described as what it is: it skips only hosts known by name alone, and it
  asserts no machine identity. Only a declared IP and a universally administered MAC are machine
  evidence. Hosts that declare only a Proxmox guest reference or a locally administered MAC are
  still emitted, as before, so that a complete aggregate does not expire their AWX membership and
  retire their records. The emitted host set does not change.
- Proxmox v3 provider references are parsed for a node name by `IntegrationIdentity`, the module
  that renders them. The previous parser expected one component fewer than the rendered format,
  so it never found the node of a v3 node reference, and for a cluster named `node` or `host` it
  returned the wrong component. A v3 guest reference carries no node name; a guest's node comes
  from its host reference.
- No data repair is part of this change. Records merged by the old rule stay merged until a
  separately planned repair undoes them from the merge audit.

## Impact
- Affected specs: device-identity-reconciliation
- Affected code: `ServiceRadar.Inventory.DeviceDiscoveryIngestor` (AWX guest binding and holder
  lookups), `ServiceRadar.Inventory.HypervisorEnrichmentIngestor` (AWX candidates for a guest, node
  names from provider references), `ServiceRadar.Inventory.IntegrationIdentity` (v3 node names),
  the AWX Wasm plugin (`go/cmd/wasm-plugins/awx`, inventory sync emission gate)
- AWX hosts whose only link to a guest was the node name and VMID (no guest agent address and no
  universally administered NIC MAC) stop binding to that guest. Guests created by Proxmox before
  it assigned its own OUI carry locally administered NIC MACs; those bind on the address only.
