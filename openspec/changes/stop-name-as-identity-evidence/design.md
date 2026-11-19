# Design: Stop treating name or hostname as identity evidence

## Context
The product owner's direction is that a name is never a strong identifier: many hosts share a
name. A read-only survey of `staging` found every place a name or hostname joins records or
picks a device. They fall into four classes:

- **A: a name is positive evidence** that merges, adopts, claims, restores or resolves a record
  onto a device.
- **R: review only.** A name already only opens a de-duplication task.
- **T: attribution by name.** A name picks the device an event, finding or lookup belongs to,
  without merging records.
- **B: guards.** A name (or its presence) only keeps records apart.

Not found: a hostname identifier type or alias type, and any `platform.*` SQL function that
matches on a name. The DIRE identity model (`docs/docs/dire-identity-model.md`) and the formal
model (`formal/dire/DireResolution.tla`) describe the A-class behavior as intended, so both
change with this proposal (as follow-up tasks, not in the proposal PR).

### Inventory and disposition
Paths are under `elixir/serviceradar_core/lib/serviceradar/` unless stated. Line numbers are as
of the proposal's base commit and will drift.

| Id | Site | Today | Disposition |
|----|------|-------|-------------|
| A1 | `inventory/sync/device_writes.ex` `resolve_record_active_ip/7` (1026), `adopt_on_hostname_agreement?/4` (1366), `hostname_adoption_refusal/4` (1381), `record_hostname_agreement/4` (1474), `hostnames_agree?/2` (1623) | A strong record that is not yet a device adopts the address holder's uid when hostnames agree and no guard refuses | Review only (D2) |
| A2 | `inventory/identity/source_succession.ex` `corroborate/4` (988), `paired?/1` (1054), `review_reason/1` (1080); `inventory/remediation/source_succession_merge.ex` | Unique shared MAC plus hostname under the time guard merges | Review only (D3) |
| A3 | `inventory/identity/source_reactivation.ex` `qualify/4` (521) | Shared MAC plus hostname returns a retired id | Review only (D3) |
| A4 | `inventory/identity/source_corroboration.ex` `corroboration/2` | Returns `{:ok, :hostname}` | First-seen only (D3) |
| A5 | `inventory/device_discovery_ingestor.ex` `reconcile_one_awx_update/3` (1309), `awx_claim_type/2` (1442), `lookup_ip_holder/3` (1498), `ip_holder_corroboration/4` (1567), `host_labels_agree?/2` | First-label agreement at `ansible_host` merges (`awx_host_network_match`) and claims agent-managed devices (`:host_inventory_record`) | Review only (D4) |
| A6 | `inventory/device_discovery_ingestor.ex` `integration_id/2` (812), `prefixed_identifier/2` | Mints `<source>:<kind>:<serial or hw id or hostname/name/host or MAC>` | Stable id, then MAC, then none (D6) |
| A7 | `go/cmd/wasm-plugins/awx/identity.go` `awxLegacyIDs` (62-83); `inventory/identity/ids.ex` `get_identifier_values(:integration_id, _)` (519); `lookup_awx_integration_owner/2` (1398); `inventory/identity/awx_source_retirement.ex` | `awx:host:<name>` looked up as a legacy id | Retired as a lookup key (D5) |
| A8 | `inventory/hypervisor_enrichment_ingestor.ex` `resolve_existing_device_uids/2` (1156), `lookup_devices/3` (1692), `device_lookup_sql/0` (1729), `maybe_lookup_device_by_record_name/2` (3174) | `LOWER(name)`/`LOWER(hostname)` fallback, last row wins in a map | Name dropped as a key (D7) |
| A9 | `inventory/proxmox_enrichment_ingestor.ex` `device_uid_for_node/3` (892), `same_host_or_node?/2` (969); `inventory/integration_identity.ex`; `go/cmd/wasm-plugins/proxmox/identity.go` | Node name scoped to cluster/provider (v2/v3 ids) | Kept (D8) |
| A10 | `camera/inventory_ingestor.ex` `lookup_device_by_hostname/2` (2232) and its fallbacks (1926, 1979-1995, 2070) | Unpartitioned `hostname ==` read with `limit(1)` | Name dropped as a key (D9) |
| A11 | `elixir/web-ng/lib/serviceradar_web_ng/devices/manual_device_creator.ex` `find_existing_matches/3` (217), `lookup_by_hostname/3` (256), `canonical_rank/1`, `resolve_live_target/2`, `merge_active_duplicates` | A hostname match (including tombstones) is updated, restored or merged | Review only, never restores (D10) |
| A12 | `inventory/remediation/agent_links.ex`, `decisions.ex` `device_matches_host?/2`, `choose_device_owner/2` | Hostname decides ownership, shared-device owner and relocation/restore candidates | Agent id only (D11) |
| A13 | `inventory/remediation/proxmox_dups.ex` | Groups by hostname, merges only on a MAC or host ref | Kept as narrowing (D11) |
| A14 | `inventory/remediation/test_debris.ex`, `decisions.ex` `debris_device?/2` | Soft-deletes devices whose hostname is in a fixed list | Key on uid (D11) |
| R | `inventory/identity/agent_corroboration.ex` (`agent_corroboration_not_identity`); the A1 refusal decision; succession `overlapping_hostname` and `corroborated_without_mac` reviews | Review only | Unchanged |
| T1 | `event_writer/device_correlation.ex` `resolve_uncached/1` (108), `lookup_device_by_hostname/2` (438) | Hostname then name, unpartitioned, sorted `limit(1)` | Unique last resort (D12) |
| T2 | `event_writer/processors/falco_events.ex` `inferred_agent_id/1` (527), `trivy_reports.ex` `inferred_agent_id/1` (1428) | `agent-<hostname>` used as the agent key and stored | Removed (D12) |
| T3 | `event_writer/processors/k8s_nodes.ex` `lookup_device_uid/1` (318) | `hostname = $1 ORDER BY uid LIMIT 1` | Unique last resort (D12) |
| T4 | `snmp_profiles/credential_resolver.ex` `device_uid_for_host/2`, `lookup_device_uid_by_fields/2` (891) | ip, then hostname, then name, lowest uid wins | Unique last resort for the name arms (D12) |
| T5 | `network_discovery/mapper_results_ingestor.ex` `build_topology_device_index/1` (4251), `resolve_topology_uid/6` (4137), `topology_name_candidates/1` | Neighbor system name and its short label, first entry wins, unpartitioned | Unique last resort (D12) |
| B | `DeviceWrites.ip_only_holder?/1` (1735); `IntegrationIdentity.ambiguous_name_keyed?/1`; proxmox-dups strong host refs; hypervisor `node_candidate?/2` and AWX node-name narrowing; `FAKER-*` exclusions; mapper endpoint-attachment checks | Keep apart or narrow | Kept (D13) |

## Goals / Non-Goals
- Goals:
  - No automatic or operator-initiated create path joins records, claims a device or revives a
    tombstone because a name agrees.
  - Wherever a name match was the only link, an operator sees the pair in the existing
    de-duplication review queue.
  - Attribution by name happens only as the last key and only on a unique match in scope.
  - The spec, the DIRE identity doc and the formal model say the same thing.
- Non-Goals:
  - Undoing merges that name evidence made in the past. They stand; open check OC4 counts them
    so an operator can review them through the existing unmerge path.
  - Changing address-based behavior (the manual creator's IP match and duplicate merge, the
    credential resolver's IP arm, the AWX unanchored-holder address match). Those follow
    "Address Is Evidence, Not Identity" and are out of scope.
  - Read-only diagnostics that take a hostname as input (the MCP `trace_device_identity` tool,
    SRQL filters). They identify nothing.
  - New decision kinds, new tables or a new review UI.

## Decisions

### D1. One rule, one review shape
A name never joins two records and never counts toward a corroboration. Where a path formerly
joined on a name and the name was the only link, it writes the record by its other evidence and
records `DecisionLog.record(:policy_block, "hostname_agreement_not_identity", [record_uid,
matched_uid], subject: address_or_nil, source: <path>, evidence: %{"name" => ..., "ip" => ...,
"incoming_device_uid" => ..., "existing_device_uid" => ...})`. The reason already exists in
`IdentityDecision` and already opens a task, so the queue, notifier and fingerprints need no
change. The `source` names the path: `sync_ip_hostname_agreement` (existing), `awx_host_name`,
`hypervisor_name`, `camera_hostname`, `manual_device_hostname`.

A task is opened only when the name matched exactly one candidate: the live address holder (A1,
A5), the single live device in the record's partition carrying the name (A8, A10, A11), or, for
a manual add or CSV import that matches no live device, the single soft-deleted device in the
partition carrying the name (A11). The tombstone a review names stays deleted. A name shared by
several live devices opens no task, because a task over many same-named devices is not
actionable and a common name (for example a default appliance name) would flood the queue. The
manual creator still reports such a collision to the operator (D10).

- Alternatives considered: a new decision kind `name_match_review`. Rejected: the existing
  reason states exactly this, and a new kind would touch the queue filters and the decision
  fingerprint for no behavioral gain.

### D2. Sync adoption on hostname agreement is removed (A1)
`resolve_record_active_ip/7` keeps the provisional-seed adoption and otherwise goes straight to
`claim_address_from_holder/5`. `adopt_on_hostname_agreement?/4` and `hostname_adoption_refusal/4`
are deleted, together with the helpers only they call (`third_party_identity_claim?/5`,
`conflicting_integration_identity?/5`, `compatible_identity_claims?/2` if no other caller
remains; verify before deleting). A new strong record that collides on an address with a live
holder whose hostname agrees is written as its own device, and the pair is recorded per D1
whatever the holder holds, so the record never forks from the holder silently; the address
itself is decided by "Address Is Evidence, Not Identity". The evidence drops the `refusal`
field, because there is no adoption left to refuse. The `[:serviceradar, :identity_reconciler, :hostname_agreement, :refused]` telemetry
event stays, without the `refusal` tag.

### D3. Succession and reactivation corroborate on first-seen time only (A2, A3, A4)
`SourceCorroboration.corroboration/2` returns `{:ok, :first_seen}` or `:error`; the hostname
branch and the time guard go. `normalize_hostname/1` stays for review classification and
evidence. In `SourceSuccession`:
- `corroborate/4` keeps only the first-seen branch; the merge audit's corroborating field is
  always `first_seen`.
- the `@hostname_holders_sql` snapshot and `unique_names/3` existed only to stop a shared
  hostname corroborating; they go, which also removes a query from every pass.
- `review_reason/1` keeps its order: `not_one_to_one`, `shared_mac`, `overlapping_hostname`
  (a linking MAC and a shared hostname without first-seen agreement, whatever the source
  times), `mac_only`, `corroborated_without_mac` (equal hostname and first-seen time without a
  MAC). A hostname may classify a review; it never decides a merge. An equal first-seen time
  without a MAC and without a shared hostname still records nothing, because bulk imports give
  many unrelated records one first-seen time.
- the remediation step `source-succession` follows: its class 2 (MAC and hostname) merges only
  when the first-seen time also agrees, and otherwise records the `overlapping_hostname` review.

`SourceReactivation.qualify/4` drops the hostname from both observations; a MAC plus a hostname
without first-seen agreement yields `source_id_reissued`, which already opens a task.

`BlockFingerprint` `@rule_version` goes from 2 to 3, so every blocked component and pair is
evaluated once under the new rules (requirement "Blocked Components Are Not Retried
Unchanged").

### D4. AWX host-label agreement is a review and claims nothing (A5)
`host_labels_agree?/2` no longer feeds `ip_holder_corroboration/4` or `awx_claim_type/2`:
- the `"ip_host_name"` corroboration is removed; an address match is accepted only by an
  overlapping universally administered MAC, a Proxmox guest anchor, or a holder without MACs,
  and a MAC contradiction still refuses it;
- the claim type is `:host_inventory_record` only for a MAC match; every other accepted match
  claims as `:managed_child_asset`, which an agent-managed device refuses;
- when the address holder's label agrees but no non-name evidence accepted the match, the AWX
  update stays on its own record and the pair is recorded per D1 with source `awx_host_name`.

This supersedes `add-awx-host-address-corroboration` (see proposal). The consequence is that an
AWX host whose only link to an agent-managed device is its name at that address stays a
separate record, carrying `ansible_managed`, until an operator merges the pair from the queue.

### D5. AWX legacy name-keyed ids are retired as lookup keys (A7)
- The AWX plugin stops computing `awxLegacyIDs` and stops emitting `legacy_integration_ids`.
- Core ignores `awx:host:` values wherever it reads legacy integration ids, in the same place
  it already drops ambiguous Proxmox values (`Ids.get_identifier_values(:integration_id, _)`),
  and `lookup_awx_integration_owner/2` reads only controller-scoped ids. Because those are
  unique per live record, its `ORDER BY last_seen DESC LIMIT 1` pick is replaced by "exactly one
  owner, otherwise none".
- `AwxSourceRetirement` keeps archiving `awx:host:` rows it finds, which is the cleanup path for
  any that remain. Independently of a retirement, task 3.8 archives the live `awx:host:` rows
  and migrates or archives `awx:host:` references held in device
  metadata (`integration_id` and `legacy_integration_ids`), not only identifier rows; OC2 found
  such references on one deployment. Removing a reference merges or splits no device. An older plugin that still sends legacy ids during a rolling upgrade is
  harmless, because core ignores them.

### D6. Derived integration ids never key on a name (A6)
`prefixed_identifier/2` becomes: plugin-supplied integration id (already preferred by
`integration_id/2`), then serial, then stable hardware id, then a normalized universally
administered unicast MAC, then nil. The hostname/name/host leg is removed, and a locally
administered MAC no longer keys an id (requirement "Randomized MACs Are Evidence Only"): two
serial-less sightings that share a randomized MAC must not resolve as one device through it.

Existing rows: an ingest-minted `<source>:<kind>:<name>` `integration_id` stays on its device.
Nothing mints it again, so nothing looks it up: it is inert history. Integration ids are not
source-authoritative, so absence retirement does not touch them, and nothing merges, splits or
rewrites a device for them. An operator can find them with OC1. AWX `awx:host:` values are the
exception: they are archived and their metadata references migrated or archived (D5, task 3.8),
which also merges or splits no device.

An update with no stable id, no MAC of any kind and no address would otherwise get a random uid
and become a new device on every sighting. It is not written; the ingest outcome counts it as unresolved
(reason `no_identity_evidence`). This is an interpretation of "then none (resolve by normal
evidence)" for the case where there is no normal evidence. An update whose only evidence is a
locally administered MAC is still written: that MAC keys no `integration_id`, and the update
resolves through the uid-seed exception of "Randomized MACs Are Evidence Only".

Rotating MACs: the comment on `prefixed_identifier/2` and the test "prefers hostname over MAC so
rotating MACs cannot rotate the id" (`device_discovery_ingestor_test.exs:264`) exist because a
device whose MAC rotates got a stable key from its hostname. After this change such a device
needs a plugin-supplied stable id (the external inventory plugin contract,
`add-external-inventory-wasm-plugin-contract`, already requires source instance plus object id).
Without one it resolves by its address and MAC, and a MAC change may create a new record. That
churn is an accepted trade-off: a stable wrong merge of two same-named devices is worse than a
visible duplicate.

### D7. Hypervisor enrichment does not look devices up by name (A8)
`resolve_existing_device_uids/2` stops collecting names; `lookup_devices/3` reads by uid only;
`device_lookup_sql/0` loses the `LOWER(name)`/`LOWER(hostname)` arms; `by_name`,
`maybe_lookup_device_by_record_name/2` and `lookup_device_by_record_name/2` go. Hosts and guests
resolve through scoped integration ids, node candidates and network (MAC) identity, as they
already do first. A host or guest record that then becomes its own device while exactly one live
device in its partition carries its name is recorded per D1 with source `hypervisor_name`. The
test "hostname-only guest lookup skips a source_retired record ..."
(`awx_source_retirement_test.exs:230`) loses its premise and is replaced by one asserting the
guest is not resolved by name at all.

### D8. Scoped Proxmox node names stay identity (A9)
A node name inside a v2 (`proxmox:v2:<cluster>:node:<node>`) or v3 (source-scoped) integration
id is a provider-issued id scoped to its cluster and provider, and stays identity.
`ambiguous_name_keyed?/1` keeps rejecting unscoped `proxmox:` values.
`device_uid_for_node/3` binds a node to the target's configured `device_id` when the node name
matches the configured target's hostname; that match is scoped to one configured target (one
cluster) and is kept. Its fallback for a target without a trusted source scope mints the uid
seed `proxmox:pve:<node>`, which is not scoped by cluster. OC3 checks whether any deployment
reaches that path; if one does, the seed is derived from the cluster-scoped id instead (task
5.4).

### D9. Camera inventory does not resolve by hostname (A10)
Every `lookup_device_by_hostname/2` fallback goes; when the descriptor's hints and the
reconciler find nothing, the camera resolves through `IdentityReconciler.resolve_device_id/2`
(or stays unresolved, as `default_resolve_device_uid/3` already allows). A camera device written
while exactly one live device in its partition carries its hostname is recorded per D1 with
source `camera_hostname`. These fallbacks have no tests today; this change adds them.

### D10. Manual add and CSV import treat a hostname match as a review (A11)
`find_existing_matches/3` keeps the uid, IP and IP-identifier lookups and drops
`lookup_by_hostname/3` as a match source; `:hostname` leaves `canonical_rank/1`. A hostname-only
submission still resolves its address by DNS first (`resolve_hostname_ip/1`), and a submission
whose name does not resolve still fails with `:missing_device_address`. After the device is
written, the creator looks up live devices in the partition with the same hostname, other than
the written one:
- exactly one: recorded per D1 with source `manual_device_hostname`;
- none live, exactly one soft-deleted: recorded per D1 against that tombstone, with source
  `manual_device_hostname`; the tombstone stays deleted and is not updated;
- several: no task; the LiveView result and the CSV import row report the collision and its
  count.
A tombstone matched only by hostname is never restored and never updated. The callers (CSV
import, device management, scan results) need no change beyond surfacing the new result.

This reverses part of `update-manual-device-hostname-readd`: re-adding a hostname whose older
hostname-only record has no address now creates a new device and a review, instead of updating
the old record.

### D11. Remediation steps stop using hostnames as ownership or deletion evidence (A12-A14)
- `agent-links`: an agent owns a device only when the device holds the agent's `agent_id`
  identifier (or its `agent_id` column names the agent). `device_matches_host?/2` and
  `choose_device_owner/2` leave the ownership decision: a shared device's owner is the one
  agent it carries by agent id, and when it carries none or several, every sharing agent
  relocates. Relocation candidates come from the agent id only; no tombstone is restored because
  its hostname matches; otherwise the step creates a fresh device as it does today.
- `proxmox-dups`: kept. Hostname grouping only narrows candidates; a merge already requires a
  shared MAC or strong host ref, and same-hostname rows without one stay separate (existing
  tests `dire_remediation_test.exs:549` and `:636`). A name here can only prevent a merge.
- `test-debris`: recommended to key on device uid. The step drops the `debris_hostnames` arm
  and keeps the agent-id prefix arm (an agent id is an identifier, not a name); devices the
  prefix does not catch are passed as an explicit `debris_device_uids` list taken from the
  dry-run manifest an operator reviewed. A hostname list (`k8s-pod-a`, `k8s-pod-b`) can match a
  real device with that name; a reviewed uid list cannot. Alternative considered: retire the
  step, since it targets debris from one test date; acceptable, but keeping a uid-keyed step
  costs little and keeps the remediation runner's step set stable.

### D12. Attribution by name is a unique last resort (T1-T5)
- T1 `DeviceCorrelation.resolve_uncached/1`: the hostname and name lookups run last (already
  true), scoped to the candidate's partition when it has one, and read at most two rows; one row
  attributes, two or zero do not. An ambiguous result emits the existing correlation telemetry
  with result `ambiguous_name` and is negatively cached like a miss.
- T2 Falco and Trivy: `inferred_agent_id/1` is removed. The agent id is the one the payload
  carries, or nil; the node or host name reaches `DeviceCorrelation` only as `hostname`/`name`.
  Findings stop storing a synthesized `agent-<hostname>`. The pending
  `add-falco-runtime-findings` already specifies `ambiguous` for a hostname matching several
  devices.
- T3 `K8sNodes.lookup_device_uid/1`: exactly one live device with that hostname, else nil. A
  node record carries no partition, so the scope is the deployment.
- T4 `CredentialResolver`: the `:hostname` and `:name` arms of `lookup_device_uid_by_fields/2`
  attach only on a single live match, else `:device_not_found`. The `:ip` arm is unchanged
  (out of scope). An ambiguous host then gets no device-scoped credential override, where today
  it gets an arbitrary device's.
- T5 mapper: `build_topology_device_index/1` filters by the records' partitions, and the name
  index stores a uid only for a name (full or short label) that exactly one canonical device in
  the partition carries; a name carried by several is marked ambiguous. `resolve_topology_uid/6`
  already tries uid, canonical uid and chassis MAC or address first; an ambiguous name leaves
  the neighbor an unresolved endpoint (requirement "Unresolved endpoints remain explicit") with
  the reason in its metadata.

### D13. Guards stay (B)
- `DeviceWrites.ip_only_holder?/1` stays as is. Treating a holder that has a hostname as not an
  adoptable IP-only seed only prevents an adoption (a merge): the holder then keeps its own
  record and the incoming record takes the address under the address rules. It can never cause a
  merge, so it is consistent with "a name may keep records apart, never join them".
- `IntegrationIdentity.ambiguous_name_keyed?/1`, the proxmox-dups strong-ref requirement, the
  hypervisor and AWX node-name candidate narrowing, the `FAKER-*` exclusions, the mapper
  endpoint-attachment checks and `AgentCorroboration` (review only) are unchanged.

### D14. Pending change coordination
Six pending changes state name-as-identity behavior (listed in the proposal). Archiving any of
them after this change would replay wording this change removes, and archiving
`add-awx-host-address-corroboration` after this change would overwrite this change's copy of
"Hostname Agreement Is Not Identity". Task group 0 amends or archives each before this change is
archived. This proposal does not edit them, to keep its diff to its own change directory.

## Risks / Trade-offs
- More review tasks, fewer automatic convergences. A genuine Armis re-key that reports a new
  first-seen time, a returning id whose only second factor is the hostname, an AWX host linked
  to a device only by name, and a manual re-add by hostname now wait for an operator.
  Mitigation: each opens exactly one task per device set, and repeats only bump its count.
- Rotating-MAC plugin devices without a stable id may churn (D6). Mitigation: the plugin
  contract's stable source id.
- Updates with no stable id, no MAC of any kind and no address are dropped and counted rather
  than written (D6).
- Ambiguous names leave events, findings, readiness transitions, SNMP credential overrides and
  LLDP neighbors unattributed where an arbitrary device used to be chosen. This is the intended
  outcome; the counts are visible in telemetry and unresolved-endpoint records.
- Past name-driven merges stay merged (non-goal). OC4 lets an operator find them.

## Migration Plan
No schema change. Existing merges, decisions and tasks stand. Name-keyed `integration_id` rows
stay inert, except the `awx:host:` ones: task 3.8 archives those live rows and migrates or
archives the `awx:host:` references in device metadata, and the AWX source retirement keeps
archiving any it later finds. The rule version bump re-evaluates each blocked component once. Rollback is a
code revert; nothing written under the new rules needs undoing, because the new rules only
write fewer merges and more review decisions.

## Open Checks
Read-only queries an operator runs later on a deployment, from a CNPG `psql` session as the
read-only role. None of them writes. Results are recorded on the implementation PR with counts
only, never with hostnames, addresses or uids.

- OC1. Which plugins mint name-keyed ids (A6). Count `integration_id` rows whose value ends in
  `:<the device's hostname or name>`, grouped by the first two segments:
  ```sql
  SELECT split_part(di.identifier_value, ':', 1) AS source,
         split_part(di.identifier_value, ':', 2) AS kind,
         count(*) AS rows,
         count(*) FILTER (WHERE d.deleted_at IS NULL) AS live_rows
  FROM platform.device_identifiers di
  JOIN platform.ocsf_devices d ON d.uid = di.device_id
  WHERE di.identifier_type = 'integration_id'
    AND ((coalesce(d.hostname, '') <> ''
          AND lower(right(di.identifier_value, length(d.hostname) + 1)) = ':' || lower(d.hostname))
      OR (coalesce(d.name, '') <> ''
          AND lower(right(di.identifier_value, length(d.name) + 1)) = ':' || lower(d.name)))
  GROUP BY 1, 2
  ORDER BY rows DESC;
  ```
  Sources other than `awx` and `proxmox` in the result are the plugins whose records hit the
  hostname key; each needs a stable id before it can stop relying on one.
- OC2. AWX legacy ids (A7). Count `awx:host:` values in the live table, the archive and device
  metadata:
  ```sql
  SELECT 'live' AS place, count(*) FROM platform.device_identifiers
   WHERE identifier_type = 'integration_id' AND identifier_value LIKE 'awx:host:%'
  UNION ALL
  SELECT 'archive', count(*) FROM platform.device_identifier_archive
   WHERE identifier_type = 'integration_id' AND identifier_value LIKE 'awx:host:%'
  UNION ALL
  SELECT 'metadata', count(*) FROM platform.ocsf_devices d
   WHERE d.deleted_at IS NULL
     AND (d.metadata->>'integration_id' LIKE 'awx:host:%'
          OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(
                       CASE WHEN jsonb_typeof(d.metadata->'legacy_integration_ids') = 'array'
                            THEN d.metadata->'legacy_integration_ids' ELSE '[]'::jsonb END) v
                     WHERE v LIKE 'awx:host:%'));
  ```
- OC3. Name-bearing provider refs (A9). Count unscoped Proxmox values and uids:
  ```sql
  SELECT 'unscoped_integration_id' AS what, count(*) FROM platform.device_identifiers
   WHERE identifier_type = 'integration_id' AND lower(identifier_value) LIKE 'proxmox:%'
     AND lower(identifier_value) NOT LIKE 'proxmox:v2:%'
     AND lower(identifier_value) NOT LIKE 'proxmox:v3:%'
  UNION ALL
  SELECT 'unscoped_node_uid', count(*) FROM platform.ocsf_devices
   WHERE uid LIKE 'proxmox:pve:%' AND deleted_at IS NULL;
  ```
  Migration `20260906150000_archive_proxmox_name_keyed_identifiers` already archived the
  unscoped integration ids it found, so a non-zero `unscoped_integration_id` means a writer is
  still minting them. A non-zero `unscoped_node_uid` means the no-source-scope fallback of
  `device_uid_for_node/3` is reachable (task 5.4).
- OC4. Past name-driven merges (non-goal, for operator review). Count merge audit rows whose
  corroboration was a name:
  ```sql
  SELECT reason, details->>'corroboration' AS corroboration, count(*)
  FROM platform.merge_audit
  WHERE (reason IN ('awx_host_network_match', 'awx_proxmox_network_match')
         AND details->>'corroboration' = 'ip_host_name')
     OR (reason = 'source_succession' AND details::text LIKE '%"field": "hostname"%')
  GROUP BY 1, 2;
  ```
  Verify the `details` key layout against one row first; the succession evidence may be nested.

### Results on one deployment
Run on 2026-11-18 on one deployment (demo), read-only, counts only. The checks stay for every
other deployment.

- OC1: `awx`/`host` 17 rows (17 live); `proxmox`/`v3` 6 rows (6 live), the cluster-scoped node
  ids that D8 keeps. No other source appeared among the `integration_id` rows the query reads
  (live and deleted devices, value suffix equal to the device's current hostname or name).
  Name-keyed values whose suffix is not a current hostname or name, values in device metadata
  and values in the archive are outside OC1; OC2 covers the `awx:host:` ones only.
- OC2: `awx:host:` values 17 live, 32 archived, 60 in device metadata (`integration_id` or
  `legacy_integration_ids`). The A7 cleanup must therefore migrate or archive the metadata
  references as well as the rows (task 3.8).
- OC3: `unscoped_integration_id` 0 and `unscoped_node_uid` 0. The no-source-scope fallback of
  `device_uid_for_node/3` is not reachable there; task 5.4 stays conditional on other
  deployments.
- OC4: 2 `awx_host_network_match` merges with `ip_host_name` corroboration; 0 merge audit rows
  with reason `source_succession`. Past merges stand (non-goal).

## Open Questions
- None blocking. OC1-OC3 decide whether task 5.4 is needed and which plugins need a stable id;
  they do not change the rules.
