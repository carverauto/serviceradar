# Change: Stop treating name or hostname as identity evidence

## Why
The product owner's direction, verbatim: "i dont think using name for a strong identifier is ever
a good idea, we have lots of hosts with the same name, so do a lot of people".

DIRE already says "Hostname Agreement Is Not Identity", but the rule only forbids merging two
existing devices on hostname agreement. Elsewhere a name or hostname still joins records: it
adopts an address holder at sync time, corroborates source-id succession and reactivation,
corroborates an AWX host's address match and lets the AWX record claim an agent-managed device,
keys plugin `integration_id` values, keys legacy AWX ids, is the fallback lookup for hypervisor
and camera records, and decides whether manual add and CSV import update, restore or merge an
existing device. Several attribution paths also pick one of several same-named devices with an
arbitrary order or a `LIMIT 1`. Same-named hosts are common (lab nodes, cloned images, default
appliance names, reused node names across clusters), so every one of these paths can fuse or
mis-attribute unrelated devices.

## What Changes
- **BREAKING (identity behavior)** A name or hostname match never merges, adopts, claims,
  restores or resolves a record onto a device by itself. Where it used to, the record is written
  by its other evidence and the pair goes to the de-duplication review queue as a `policy_block`
  identity decision with reason `hostname_agreement_not_identity`. This covers:
  - sync hostname-agreement adoption of an address holder (`DeviceWrites`): adoption and its
    refusal checks are deleted, and a new strong record that collides on an address with a live
    holder of the same hostname is written as its own device with the review recorded, never
    forked silently;
  - AWX host-label agreement at an `ansible_host` address, which no longer merges and no longer
    claims an agent-managed device (`DeviceDiscoveryIngestor`);
  - the hypervisor enrichment name/hostname fallback (`HypervisorEnrichmentIngestor`);
  - the camera inventory hostname fallback (`Camera.InventoryIngestor`);
  - manual device add and CSV import in web-ng (`ManualDeviceCreator`), where a hostname match no
    longer updates, restores or merges a device and never revives a tombstone; when the only
    match is one soft-deleted device, the review names that tombstone, which stays deleted.
  A review is opened only when the name matches exactly one candidate.
- **BREAKING (identity behavior)** Source-id succession and reactivation corroborate only on
  non-name evidence: a unique shared universally administered MAC plus an agreeing source
  first-seen time. A shared MAC whose only second factor is the hostname becomes a review
  (`succession_review` / `source_id_reissued`) instead of a merge or return. The D3 hostname time
  guard is retired.
- Plugin `integration_id` minting no longer falls back to a hostname/name. The key is a
  plugin-supplied stable id (explicit integration id, serial or stable hardware id), then a
  universally administered MAC, then none; a locally administered MAC never keys one. Existing name-keyed rows stay as inert history; nothing merges or splits.
- AWX legacy name-keyed ids (`awx:host:<name>`) are retired as lookup keys in the plugin and in
  core. Existing `awx:host:` rows are archived and the `awx:host:` references held in device
  metadata are migrated or archived, without merging or splitting a device; the AWX source
  retirement still archives any that remain.
- Remediation steps stop using a hostname as ownership or deletion evidence: `agent-links`
  decides by agent id only, and `test-debris` keys on device uid and agent id, not a hostname
  list.
- Attribution paths (EventWriter device correlation, Falco and Trivy, K8s node readiness, SNMP
  credential host lookup, mapper LLDP/CDP neighbor resolution) use a name only as the last key,
  after uid, agent/workload id, address and MAC, and attach only when exactly one live device in
  scope matches. Ambiguous names stay unattributed with the reason recorded where outcomes are
  recorded today. No path derives another key (such as `agent-<hostname>`) from a name.
- Kept as is: Proxmox node names scoped to their cluster and provider remain identity, as a
  provider-issued scoped id; unscoped names stay rejected (`ambiguous_name_keyed?`). The
  `ip_only_holder?` rule that a holder with a hostname is not an adoptable IP-only seed stays,
  because it only prevents merges.
- The DIRE formal model and docs are updated in follow-up tasks of this change (not in this
  proposal PR): hostname adoption leaves `DireResolution.tla`, hostname corroboration becomes a
  rejected alternative, and the re-key-with-new-first-seen goal expects a review instead of a
  merge.

## Relationship to pending changes
These pending changes carry deltas that state name-as-identity behavior. Each MUST be amended
or archived before this change is archived (task group 0), so that no archive replays wording
this change removes:

- `add-awx-host-address-corroboration` (implemented, not archived) MODIFIES "Hostname Agreement
  Is Not Identity" to let AWX host-name agreement corroborate an exact address match and merge
  into, and claim, the holder. This change supersedes that rule: label agreement opens a review
  and never merges or claims. It MUST be archived before this change, so that this change's
  MODIFIED copy of the requirement is the one that lands in `specs/`; archived after, it would
  restore the corroboration wording.
- `add-ansible-integration` (device-inventory, ADDED "Ansible-Managed Device Linkage Derived
  from AWX Inventory"): scenario "AWX host matches a device by address and host name" merges on
  label agreement. Its ansible-integration delta ("AWX Inventory as a Plugin-Emitted Discovery
  Source", scenario "Plugin emits AWX hosts; DIRE merges with existing devices") merges an AWX
  host into the device with the same name and `ansible_host`. Amend both to the review outcome.
- `add-device-delete-guardrails`: its MODIFIED "Restore Soft-Deleted Devices" restores a
  source-retired device when its id returns "with the archived MAC and hostname", and lacks the
  rule that a name match never restores. Amend it to this change's wording (archived MAC and
  first-seen time), or archive it before this change so that this change's MODIFIED copy lands
  last.
- `update-manual-device-hostname-readd` (implemented, not archived): ADDED "Manual Device
  Re-add Reconciliation" merges a hostname-only duplicate, and its device-inventory "OCSF Device
  Schema" scenarios update or restore a device matched by hostname. Amend to: hostname matches
  open a review and never restore.
- `refactor-device-identity-reconciliation`: ADDED "Cross-Source Identity Bridging" registers a
  normalized hostname as a "medium-confidence corroborating identifier" and converges agent and
  Proxmox records on MAC and hostname. Amend to drop hostname as corroboration; the MAC carries
  the convergence.
- `link-agent-host-by-strong-identity`: ADDED "Same-Named Hosts Without A Shared Strong
  Identifier Never Fuse" says mapper/MAC holders "remain eligible for adoption" on hostname
  agreement and names a refusal `agent_bound_holder`. Amend: no holder is adopted on hostname
  agreement, and the decision carries no refusal classification.

Aligned, no amendment needed: `add-falco-runtime-findings` (an ambiguous hostname lookup
yields `ambiguous` and no device), `add-external-inventory-wasm-plugin-contract` (source
instance plus object id keys an external object), `add-distinct-guest-identity-merge-guard`
and `add-agent-self-report-device-identity` (hostname overlap never merges).

## Impact
- Affected specs: `device-identity-reconciliation` (MODIFIED "Source-Authoritative Identifiers
  Govern Identity", "Hostname Agreement Is Not Identity", "Corroborated Source Identifier
  Succession", "Retired Source Identifiers Are Reserved"; ADDED "Name Attribution Is A Unique
  Last Resort", "Integration Identifiers Are Not Name-Keyed"), `device-inventory` (MODIFIED
  "Restore Soft-Deleted Devices"), `dire-formal-model` (MODIFIED "Source Identifier Change Is
  Modeled", "Rejected Identity Alternatives Have Negative Configurations").
- Affected code (core, `elixir/serviceradar_core/lib/serviceradar/`):
  `inventory/sync/device_writes.ex`, `inventory/identity/source_succession.ex`,
  `inventory/identity/source_reactivation.ex`, `inventory/identity/source_corroboration.ex`,
  `inventory/identity/block_fingerprint.ex`, `inventory/identity/ids.ex`,
  `inventory/device_discovery_ingestor.ex`, `inventory/hypervisor_enrichment_ingestor.ex`,
  `inventory/proxmox_enrichment_ingestor.ex`, `camera/inventory_ingestor.ex`,
  `inventory/remediation/{agent_links,decisions,test_debris,source_succession_merge}.ex`,
  `event_writer/device_correlation.ex`, `event_writer/processors/{falco_events,trivy_reports,k8s_nodes}.ex`,
  `snmp_profiles/credential_resolver.ex`, `network_discovery/mapper_results_ingestor.ex`.
- Affected code (other): `elixir/web-ng/lib/serviceradar_web_ng/devices/manual_device_creator.ex`
  and its callers (CSV import, device management, scan results); `go/cmd/wasm-plugins/awx/identity.go`.
- Docs and model (follow-up tasks): `docs/docs/dire-identity-model.md`, `docs/docs/ansible.md`,
  `formal/dire/DireResolution.tla`, its configurations and traces, `formal/dire/README.md`.
- Operators: some devices that used to converge automatically will appear in the
  de-duplication review queue instead, notably an Armis re-key whose new id carries a new
  first-seen time, an AWX host whose only link to a device is its name at that address, and a
  manual re-add matched only by hostname.
