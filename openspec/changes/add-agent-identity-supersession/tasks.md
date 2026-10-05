# Tasks

- [x] 1.1 Migration: `superseded_by`, `superseded_at` and a partial `device_uid` index on
      `platform.ocsf_agents`. Helm `core.migrations.expectedVersion` tracks that migration.
- [x] 1.2 `Agent`: `:superseded` status, `:supersede` / `:revive_superseded` transitions and
      actions, and an `upsert_condition` on `:register_connected` so it cannot revive a
      superseded row.
- [x] 1.3 `AgentSupersession`: same-device rule at check-in (live identities kept), fleet
      sweep, explicit revival, and `agent_supersession` identity decisions.
- [x] 1.4 `AgentGatewaySync`: call the new rule at check-in, revive on heartbeat or hello
      under a superseded uid, and drop the address-matched retirement.
- [x] 1.5 `PruneStaleAgentsWorker`: run the sweep hourly before retiring stale rows.
- [x] 1.6 Rollouts: the coordinator drops superseded agents from targets, and the profile
      reconciler skips them.
- [x] 1.7 SRQL: `status`, `superseded_by`, `superseded_at` columns; default exclusion; lifted
      by `include_deleted:true` or a lifecycle filter.
- [x] 1.8 web-ng: catalog fields and decision kind, and the agent detail page loads
      superseded identities.
- [x] 1.9 Tests: re-enrollment regression (fails on the previous code), live identity
      kept, NAT address not retired, revival, sweep, and SRQL unit tests.
