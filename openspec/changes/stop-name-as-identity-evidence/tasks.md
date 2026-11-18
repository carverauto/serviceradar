Test rules for every group: load the `test-audit` skill before writing or changing a test.
A test marked **regression** MUST fail on the code this change starts from and pass after it;
record the failing run (command and the assertion that failed) on the implementation PR. A test
marked **guard** passes before and after, and proves non-name evidence still decides. Fixtures
are synthetic only (`*.example.com`, `192.0.2.0/24`, `198.51.100.0/24`, `00:00:5e:00:53:xx`,
invented uids and names). Unboxed database tests delete every row they create.

## 0. Pending change coordination (before this change is archived)
- [ ] 0.1 Archive `add-awx-host-address-corroboration` before this change, so that this change's
      MODIFIED copy of "Hostname Agreement Is Not Identity" is the one left in `specs/`.
- [ ] 0.2 Amend `add-ansible-integration` (device-inventory, scenario "AWX host matches a device
      by address and host name", and `specs/ansible-integration/spec.md` "AWX Inventory as a
      Plugin-Emitted Discovery Source", scenario "Plugin emits AWX hosts; DIRE merges with
      existing devices", which merges an AWX host by name and `ansible_host`) to the review
      outcome of D4.
- [ ] 0.3 Amend `update-manual-device-hostname-readd`: "Manual Device Re-add Reconciliation" and
      the device-inventory "OCSF Device Schema" scenarios must not update, restore or merge a
      device matched only by hostname (D10).
- [ ] 0.4 Amend `refactor-device-identity-reconciliation` "Cross-Source Identity Bridging" to
      drop the normalized hostname as a corroborating identifier; agent and Proxmox records
      converge on the MAC.
- [ ] 0.5 Amend `link-agent-host-by-strong-identity` "Same-Named Hosts Without A Shared Strong
      Identifier Never Fuse": no holder is adopted on hostname agreement, and the decision
      carries no `agent_bound_holder` refusal.
- [ ] 0.6 Amend `add-device-delete-guardrails` MODIFIED "Restore Soft-Deleted Devices" (scenario
      "A returning source id restores a source-retired device" restores by the archived MAC and
      hostname) to this change's wording: archived MAC and first-seen time, and no name match
      restores. Otherwise archive it before this change, so that this change's copy lands last.
- [ ] 0.7 Before archiving, re-run `grep -rn -i "hostname" openspec/changes/*/specs` (excluding
      `archive/`) and fix any other pending delta that states a name as identity evidence.

## 1. Sync active-IP adoption (A1, D2)
- [ ] 1.1 In `DeviceWrites.resolve_record_active_ip/7`, remove the hostname-agreement adoption
      branch; delete `adopt_on_hostname_agreement?/4`, `hostname_adoption_refusal/4` and every
      helper only they call (check each for other callers first).
- [ ] 1.2 When a new strong record collides on an address with a live holder whose hostname
      agrees and the holder is not adopted as a provisional seed, write the record as its own
      device (never refuse or drop it) and record the `policy_block` /
      `hostname_agreement_not_identity` decision naming both; evidence carries the hostname,
      address and both uids, no `refusal`. **Regression**: spec scenario "A new record colliding
      with a same-hostname address holder opens a review".
- [ ] 1.3 **Regression**: invert `sync_ingestor_vendor_type_test.exs` "a later strong
      integration converges when hostname agrees and no third identity claims it" (line 767):
      the two stay separate and a decision names both.
- [ ] 1.4 **Regression**: invert `sync_batch_resolution_test.exs` "overlapping same-provider
      integration ids still attach to the holder" (line 1036) to: hostname agreement does not
      attach; a decision names both.
- [ ] 1.5 **Regression**: same-named record and holder at one address with no other evidence on
      either side stay separate with one open de-duplication task (spec scenario "Same-named
      devices at one address stay separate with a review").
- [ ] 1.6 Keep the existing refusal tests that assert separation; drop only their assertions on
      the `refusal` value.

## 2. Succession, reactivation and corroboration (A2-A4, D3)
- [ ] 2.1 `SourceCorroboration.corroboration/2` returns `{:ok, :first_seen}` or `:error`; remove
      the hostname branch and the time guard; update the moduledoc.
- [ ] 2.2 `SourceSuccession`: `corroborate/4` keeps only first-seen; remove
      `@hostname_holders_sql`, `hostname_holders/2` and `unique_names/3`; `review_reason/1`
      classifies `overlapping_hostname` on any shared hostname with a linking MAC and no
      first-seen agreement; the merge audit's corroborating field is always `first_seen`.
- [ ] 2.3 **Regression**: replace `source_succession_test.exs` "a hostname alone corroborates
      only when the new id was first seen after the old one was last seen" (line 389) with the
      spec scenario "A re-key whose only second factor is the hostname goes to review".
- [ ] 2.4 Remove the tests that only exercise the retired time guard (lines 398, 405, 808) and
      `source_corroboration_test.exs` line 97; **regression**: a shared hostname with the later id
      first seen after the earlier one was last seen returns `:error`.
- [ ] 2.5 `SourceReactivation.qualify/4` drops hostnames from both observations.
      **Regression**: invert `source_reactivation_test.exs` "returns on a shared hostname first
      seen no earlier than the id was last seen" (line 142): a new record and a
      `source_id_reissued` decision.
- [ ] 2.6 Remediation step `source-succession` (`SourceSuccessionMerge`): class 2 merges only
      with an agreeing first-seen time and otherwise records the `overlapping_hostname` review.
      **Regression**: a class 2 pair whose first-seen times differ is reviewed, not merged.
- [ ] 2.7 Bump `BlockFingerprint` `@rule_version` from 2 to 3; **guard**: the existing
      rule-version test still re-evaluates a blocked component once.

## 3. AWX inventory hosts and legacy ids (A5, A7, D4, D5)
- [ ] 3.1 `DeviceDiscoveryIngestor`: remove the `"ip_host_name"` corroboration; claim
      `:host_inventory_record` only on a MAC match; record the D1 decision (source
      `awx_host_name`) when the holder's label agrees and no non-name evidence accepted the
      match; update the comments above `awx_claim_type/2` and `ip_holder_corroboration/4`.
- [ ] 3.2 **Regression**: invert `awx_host_identity_db_test.exs` "a short AWX host name merges
      into the agent-managed device holding its address under the FQDN" (line 41): no merge, no
      claim, one decision naming both.
- [ ] 3.3 **Regression**: invert "an AWX host merges into the MAC-anchored swept device sharing
      its address and host name" (line 67): without an overlapping MAC it does not merge.
- [ ] 3.4 **Guard**: an AWX host with a different name and an overlapping universally
      administered MAC still merges; a MAC contradiction still refuses.
- [ ] 3.5 AWX plugin (`go/cmd/wasm-plugins/awx/identity.go`): delete `awxLegacyIDs` and stop
      emitting `legacy_integration_ids`; update the file comment and the Go tests.
- [ ] 3.6 Core: ignore `awx:host:` values in `Ids.get_identifier_values(:integration_id, _)` and
      in `lookup_awx_integration_owner/2`; replace its `ORDER BY ... LIMIT 1` with "exactly one
      owner, else none". **Regression**: an AWX update carrying a legacy `awx:host:<name>` id does
      not resolve to the device holding it.
- [ ] 3.7 **Guard**: `AwxSourceRetirement` still archives `awx:host:` rows (existing tests).
- [ ] 3.8 Extend the `awx:host:` cleanup to migrate or archive the references held in device
      metadata (`integration_id` and `legacy_integration_ids`), not only identifier rows (OC2
      found 60 on one deployment). **Regression**: a device whose metadata carries an
      `awx:host:<name>` reference no longer carries it after the cleanup, and no device is merged
      or split.

## 4. Derived integration ids (A6, D6)
- [ ] 4.1 `DeviceDiscoveryIngestor.prefixed_identifier/2`: remove the hostname/name/host leg,
      and key on a MAC only when it is universally administered and unicast (a locally
      administered MAC keys nothing); rewrite the "Key preference" comment and the moduledoc.
- [ ] 4.2 Skip an update with no stable id, no MAC of any kind and no address, and count it in
      the ingest outcome as `no_identity_evidence`; an update whose only evidence is a locally
      administered MAC is still written.
- [ ] 4.3 **Regression**: replace `device_discovery_ingestor_test.exs` "prefers hostname over MAC
      so rotating MACs cannot rotate the id" (line 264) with "does not key on the hostname; falls
      back to the MAC", and state the rotating-MAC trade-off in the test's name or comment.
- [ ] 4.4 **Regression**: a record with only a hostname and an address derives no
      `integration_id`; a record with only a hostname and no MAC or address is not written as a
      device; a record whose only MAC is locally administered derives no `integration_id`, and
      without an address is still written as a device.
- [ ] 4.5 **Guard**: a plugin-supplied integration id, serial or hardware id still keys the
      record ahead of the MAC.

## 5. Hypervisor enrichment and Proxmox (A8, A9, D7, D8)
- [ ] 5.1 `HypervisorEnrichmentIngestor`: remove the name collection, the name arms of
      `device_lookup_sql/0`, `by_name`, and `maybe_lookup_device_by_record_name/2` /
      `lookup_device_by_record_name/2`.
- [ ] 5.2 Record the D1 decision (source `hypervisor_name`) when a host or guest is written as
      its own device while exactly one live device in its partition carries its name.
- [ ] 5.3 **Regression**: a host or guest record whose only link to a live device is its name is
      not resolved to that device; replace `awx_source_retirement_test.exs` line 230, whose
      premise (hostname-only guest lookup) no longer exists.
- [ ] 5.4 If OC3 shows the no-source-scope path of `ProxmoxEnrichmentIngestor.device_uid_for_node/3`
      is reachable: derive the node's uid seed from its cluster-scoped id instead of
      `proxmox:pve:<node>`. **Regression**: two same-named nodes of different clusters without a
      source scope get different devices.
- [ ] 5.5 **Guard**: a scoped v2/v3 node id still resolves its node; an unscoped `proxmox:` value
      is still rejected by `ambiguous_name_keyed?/1`.

## 6. Camera inventory (A10, D9)
- [ ] 6.1 Remove every `lookup_device_by_hostname/2` fallback from `Camera.InventoryIngestor`.
- [ ] 6.2 Record the D1 decision (source `camera_hostname`) when the camera's device is written
      while exactly one live device in its partition carries its hostname.
- [ ] 6.3 **Regression** (the fallback has no tests today): a camera descriptor whose only link
      to a live device is its hostname is not attached to that device, both in
      `fallback_generated_camera_uid/4` and in `resolve_identity_from_hints/3`.

## 7. Manual add and CSV import (A11, D10)
- [ ] 7.1 `ManualDeviceCreator`: drop `lookup_by_hostname/3` from `find_existing_matches/3` and
      `:hostname` from `canonical_rank/1`; never restore or update a tombstone matched only by
      hostname.
- [ ] 7.2 After writing, look up live same-hostname devices in the partition; record the D1
      decision (source `manual_device_hostname`) for exactly one; when none is live and exactly
      one soft-deleted device carries the hostname, record the decision against that tombstone
      and leave it deleted; report a collision with its count for several in the LiveView result
      and the CSV import row result.
- [ ] 7.3 **Regression**: invert `manual_device_creator_test.exs` "updates an existing
      hostname-only manual device after resolving its IP" (line 259): a new device and one
      decision; the old record unchanged.
- [ ] 7.4 **Regression**: invert "merges active hostname-only duplicate into resolved-IP canonical
      device" (line 419): the resolved-IP device is updated, the hostname-only device is neither
      merged nor changed, and a decision names both.
- [ ] 7.5 **Regression**: a soft-deleted device matched only by hostname stays deleted, with no
      revival audit row (spec scenario "A manual re-add matched only by hostname does not
      restore a tombstone"), through both manual add and CSV import, and when no live device
      carries the hostname a decision names the new device and the tombstone.

## 8. Remediation steps (A12-A14, D11)
- [ ] 8.1 `agent-links`: ownership and shared-device owner by agent id only; relocation
      candidates by agent id only; no tombstone restore by hostname. Update `Decisions`
      (`device_matches_host?/2`, `choose_device_owner/2`) and their tests (`decisions_test.exs`
      lines 142, 153). **Regression**: an agent whose current device carries only its expected
      hostname, not its agent id, is relocated; a tombstone carrying only the expected hostname
      is not restored.
- [ ] 8.2 `proxmox-dups`: no code change; **guard**: `dire_remediation_test.exs` lines 549 and
      636 still pass.
- [ ] 8.3 `test-debris`: drop the `debris_hostnames` arm and the default hostname list; keep the
      agent-id prefix; accept an explicit `debris_device_uids` list. **Regression**: a device
      named like a former debris hostname, with no debris agent prefix and not in the uid list,
      is not soft-deleted.

## 9. Attribution by name (T1-T5, D12)
- [ ] 9.1 `DeviceCorrelation`: scope the hostname and name lookups to the candidate's partition
      when present, read at most two rows, attribute only on one; emit `ambiguous_name`
      telemetry and cache the miss. **Regression**: two live same-named devices leave the event
      unattributed. **Guard**: one attaches; an address is used before a name.
- [ ] 9.2 Falco and Trivy: delete `inferred_agent_id/1`; store and correlate only a supplied
      agent id. **Regression**: a payload without an agent id stores no `agent-<host>` id and is
      not correlated through one. Re-check `falco_events_test.exs` line 145.
- [ ] 9.3 `K8sNodes.lookup_device_uid/1`: exactly one live match, else nil. **Regression**: two
      same-named devices leave the readiness event without a device.
- [ ] 9.4 `CredentialResolver`: the `:hostname` and `:name` arms attach only on one live match.
      **Regression**: two devices with one hostname yield `:device_not_found` instead of the
      lowest uid.
- [ ] 9.5 Mapper: partition-scope `build_topology_device_index/1` and mark names (full and short
      label) carried by several canonical devices as ambiguous; leave such a neighbor an
      unresolved endpoint with the reason. **Regression**: an LLDP neighbor `sw01` with two
      `sw01.*` devices in the partition is unresolved. **Guard**: a chassis MAC still resolves.

## 10. Guards and in-code wording (B, D13)
- [ ] 10.1 Rewrite the comment above `provisional_ip_seed?/2` in `DeviceWrites` ("a hostname or
      MAC is identity evidence") to say that a hostname or MAC on the holder only keeps it from
      being adopted, which prevents a merge and never causes one; leave `ip_only_holder?/1` as is.
- [ ] 10.2 Update the `IdentityDecision` moduledoc entry for `hostname_agreement_not_identity`
      to cover every path in D1.

## 11. Docs and formal model (follow-up within this change, not in the proposal PR)
- [ ] 11.1 `docs/docs/dire-identity-model.md`: rewrite the sync adoption paragraphs (hostname
      agreement adopts nothing; remove the integration-conflict refusal paragraph), the AWX
      sentence, the succession and reactivation description (first-seen only, no time guard),
      the agent paragraph's "integration record cannot adopt an agent-bound holder by hostname"
      wording, and the telemetry table row for `hostname_agreement.refused`.
- [ ] 11.2 `docs/docs/ansible.md` step 4: host-name agreement opens a review and never merges.
- [ ] 11.3 `formal/dire/DireResolution.tla`: remove `hostAgree`/`hostAdopt` from the write
      action (adoption is `seedHold` only); make `CorroboratedBy` first-seen only; add the unsafe
      alternatives `hostname_corroborates` (hostname under the time guard) and `hostname_adopts`
      (adoption under its former refusals), keeping `overlapping_hostname_corroborates` and
      `hostname_adopts_across_integration_ids`, which re-enable hostname behavior and stay as
      negative configurations; add a goal property that no succession, adoption or reactivation
      was decided by a hostname.
- [ ] 11.4 Configurations: add `resolution_unsafe_hostname_corroborates.cfg` (an environment
      where a second device with the first's MAC and hostname enters Armis after the first has
      left it) and `resolution_unsafe_hostname_adopts.cfg` (two same-named devices of different
      integration providers at one address); delete `resolution_vacuity_hostname_succession.cfg`;
      change `resolution_goal_armis_rekey_new_first_seen.cfg` to expect separate records and a
      review; update `formal/dire/BUILD.bazel`.
- [ ] 11.5 Traces: re-record `Trace_src_rekey_new_first_seen` (now a review, no merge) and
      re-check `Trace_integration_hostname_conflict`, `Trace_agent_first_same_name` and
      `Trace_agent_same_name_two_sites` against the new write action.
- [ ] 11.6 `formal/dire/README.md`: the `Succeed` description, the environment table rows
      (`armis_clones`, `armis_rekey_new_first_seen`, `integration_clones`), the rejected
      alternatives table and the trace descriptions.

## 12. Open checks (read-only, on a deployment, after merge; design "Open Checks")
Results from one deployment are in design "Results on one deployment"; run the checks on each
other deployment before relying on them there.
- [x] 12.1 Run OC1 and record per-plugin counts; open an issue per plugin that needs a stable
      source id. One deployment: no plugin besides the AWX legacy path uses the name key, so no
      issue is needed there.
- [x] 12.2 Run OC2 and record the counts of `awx:host:` values live, archived and in metadata.
      One deployment: 17 live, 32 archived, 60 in metadata; task 3.8 covers the metadata.
- [ ] 12.3 Run OC3; if `unscoped_node_uid` is non-zero, do task 5.4. One deployment: 0 and 0,
      so task 5.4 is not needed there and stays conditional on other deployments.
- [x] 12.4 Run OC4 and record the count of past name-driven merges for operator review. One
      deployment: 2 `awx_host_network_match` merges with `ip_host_name`, 0 `source_succession`.
- [ ] 12.5 Record counts only; never paste hostnames, addresses or uids from the deployment.

## 13. Validation
- [ ] 13.1 `openspec validate stop-name-as-identity-evidence --strict`.
- [ ] 13.2 `mix format` and the `elixir-quality` lint for `serviceradar_core` and `web-ng`; `gofmt`
      and the AWX plugin's Go tests.
- [ ] 13.3 The focused database tests of groups 1-9 through the srql-fixtures scratch database or
      BuildBuddy; the TLC configurations of group 11 through Bazel.
- [ ] 13.4 Confirm each regression test failed before its fix, and list any check not run.
