## Why

Whether two enabled assignments of one plugin may coexist on one agent was
decided three different ways. `AssignmentOwner` let assignments of different
credential rules coexist, the database refused them with a unique index on
`(partition_id, agent_uid, plugin_id)`, and config delivery kept only one
assignment per plugin. Two credential rules that each scope their own target
(one agent bridging two controllers of the same kind with different tokens)
therefore could not work. Tracked in #5835.

## What Changes

- The one-enabled-assignment unique index is keyed per owner: the credential
  rule id for a rule-owned assignment, one shared key for manual and other
  policy assignments.
- The policy reconciler adopts the drifted assignment of its own rule even when
  other rules' assignments of the plugin are enabled on the agent, and prefers
  that row over a manual or other non-rule row. A credential-rule assignment is
  adopted only by that same rule, so a non-rule policy does not rewrite it.
  When nothing is adoptable, the create error is reported.
- Enabling writes of one plugin on one agent take a transaction-scoped advisory
  lock, and the duplicate check runs again under that lock.
- Config delivery delivers every enabled assignment of a plugin that does not
  conflict with a more recently updated one, each with credentials resolved
  from its own parameters. The agent already keys runners by assignment id.
- The plugin fleet view shows one row per owner instead of one per plugin.

Not changed here: plugin result service identity is still keyed by package name
per agent, so two coexisting instances share one service state row, and a few
consumers still pick one assignment per plugin (AWX verb commands, northbound
action dispatch, assignment-scoped producer schedules). These are tracked in #6006.

## Impact

- Affected specs: `wasm-plugin-system` (Per-Rule Plugin Assignment Ownership).
- Affected code: `ServiceRadar.Plugins.AssignmentOwner`,
  `PolicyAssignmentReconciler`, `SerializeEnabledAssignment`,
  `Edge.AgentConfigGenerator`, web-ng `PluginFleet`, migration
  `20261025200000_key_enabled_plugin_assignments_per_owner`.
- Database: an index swap on `platform.plugin_assignments`; Helm
  `core.migrations.expectedVersion` moves to `20261025200000`.
- Agents: no protocol change. An agent of any version already runs one instance
  per assignment id.
