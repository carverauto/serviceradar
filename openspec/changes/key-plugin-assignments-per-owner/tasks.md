## 1. Database

- [x] 1.1 Migration replacing `plugin_assignments_one_enabled_per_edge_plugin_index`
      with `plugin_assignments_one_enabled_per_edge_plugin_owner_index` on
      `(partition_id, agent_uid, plugin_id, owner key)` where enabled.
- [x] 1.2 Bump Helm `core.migrations.expectedVersion`.
- [x] 1.3 DB test: two rules coexist; the same rule under another suffix and
      two shared-key rows are refused by the index.
- [x] 1.4 Serialize enabling writes per (partition, agent, plugin) with
      `pg_advisory_xact_lock` and repeat the duplicate check under it; DB test
      with two concurrent writers.

## 2. Reconciler

- [x] 2.1 Adopt the same-owner row among all enabled assignments of the plugin;
      report the create error when there is none.
- [x] 2.2 Prefer the rule's own row over a manual or other-policy row that also
      collides.
- [x] 2.3 Unit test: own drifted row adopted while another rule's row and a
      manual row are enabled.

## 3. Delivery

- [x] 3.1 Replace the per-plugin dedupe with a per-owner conflict filter.
- [x] 3.2 DB test: two rules' assignments of one plugin are both delivered,
      each with its own credential.
- [x] 3.3 Go test: the agent runs one scheduled instance per assignment id.

## 4. UI

- [x] 4.1 Plugin fleet rows per owner, with a unit test.
- [x] 4.2 A result stamped with a sibling owner's assignment id is not drift
      while owners share one service state (#6006).

## 5. Follow-ups (#6006, not in this change)

- [ ] 5.1 Plugin result service identity per assignment.
- [ ] 5.2 AWX verb commands, northbound dispatch and assignment-scoped producer
      schedules select an assignment, not a plugin.
