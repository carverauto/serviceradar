# Tasks

## 1. Requirements

- [x] 1.1 ADDED goal requirements in `device-identity-reconciliation`; MODIFIED `device-inventory`
      "Restore Soft-Deleted Devices", with the pending copy in `add-device-delete-guardrails`
      updated to match.
- [ ] 1.2 Archive `refactor-device-identity-reconciliation` so its guarded `IP Alias Resolution`
      and `Merge Stability and Oscillation Protection` replace the unguarded wording in the
      living spec (design D1). Check first that no other pending change repeats those blocks.
- [ ] 1.3 Correct `docs/docs/dire-identity-model.md`: a globally-unique MAC may merge where it
      is the only hardware identifier; randomized MACs never do (design D4, D5).

## 2. Formal model (owned by `add-dire-formal-model`)

- [x] 2.1 Extend the model with address churn, IP aliases, identifier classes, interface
      identifiers and recorded identity decisions, and add the properties in the design's
      mapping table.
- [x] 2.2 Check the model against today's code, and record each violated requirement as a
      defect switch with a witness configuration.

## 3. Cleanup

Each confirmed defect is fixed in its own pull request. The pull request removes the defect's
model switch, deletes its witness, and adds its property to the model's must-pass
configuration. Confirmed defects (`formal/dire/README.md` has code paths and witnesses):

- [x] 3.1 `sync_alias_merge_unguarded`: the sync alias merge folds the previous holder of a
      DHCP address into the device that leased it; give it the distinct-identity veto.
- [x] 3.2 `alias_merge_on_unknown_mac`: `AliasGuard` treats an unknown MAC set as not
      distinct; an address must never merge two identified records. The real route is agent
      check-in (`AgentGatewaySync`), confirmed by trace; the mapper never reaches `AliasGuard`.
      `maybe_merge_ip_alias_device/3` no longer merges: an identified alias holder has the alias
      invalidated, an address-only holder is left alone.
- [x] 3.3 `src_attach_via_mac`: a source-authoritative id attaches through a MAC to a record
      holding a different source-authoritative id.
- [ ] 3.4 `mac_only_conflicts_blocked`: allow globally-unique MAC evidence to merge; keep
      randomized MACs excluded. The conflict arises on agent check-in; a router's per-interface
      records also stay split because of 3.13.
- [x] 3.5 `silent_blocks`: record blocked merges and alias invalidations (#4613, `add-identity-decision-log`).
- [x] 3.6 `upsert_revives_merged`: the upsert `on_conflict` must not revive a merged tombstone and
      must bump on any revival.
- [x] 3.7 `gateway_sync_no_bump`: gateway sync must restore through `:restore` or not at all.
- [x] 3.8 `follow_stale_audit`: follow a merge row only for `deleted_reason = "merged"`.
- [x] 3.9 `sweep_restores_merged`: sweep restore must skip merged tombstones.
- [ ] 3.10 `fence_observe_only`: enforce the fence (`add-device-identity-fence` task 4.5).
- [x] 3.11 `unmerge_restores_matches`: record the source's identifiers at merge time and restore
      exactly those.
- [x] 3.12 `purge_forgets_redirect`: resolve purged merged-away uids through `merge_audit`.
- [x] 3.13 `mapper_resolves_by_address` (found by trace validation): the mapper attaches a polled
      device's interface table to whichever record holds the address, or a stale alias of it;
      after DHCP churn the new device's MACs land on the old device's record and the new device
      gets no record. Resolve by the reported MACs; the address is evidence only. Fixed in
      #4638: the mapper resolves through the Resolver, so its polls now reach `AliasGuard` too.
- [x] 3.14 `stale_holder_keeps_address` (found by trace validation): a fresh source-authoritative
      write drops its address when a stale record still holds it; the stale record keeps it and
      address-only sightings attach to the wrong device. The observed device must hold its
      observed address.

## 4. Related work

- [x] 4.1 #4603: expire ephemeral devices on last-seen; never expire a device holding a hardware
      or source-authoritative identifier.
- [x] 4.2 #4604: de-duplication tasks for every blocked, declined or overridden identity decision
      (`add-identity-deduplication-tasks`; the web-ng queue and SRQL visibility are its follow-up).
