# Design: Sweep diagnostics through SRQL and MCP

## Context

The sweep data model already exists in CNPG and none of it is reachable from
SRQL. `device_agent_availability` appears in the SRQL diesel schema only as an
internal join inside device availability filters
(`rust/srql/src/query/devices/filters/availability.rs`); there is no `in:`
entity for any sweep table.

Retention today: `sweep_host_results` 7 days, `sweep_group_executions` 30 days
(`sweep_data_cleanup_worker.ex`).

## Decisions

### Per-port outcomes: one array on the existing row

`scanned_ports bigint[]` records every port the agent reported on. Closed and
no-response ports are `scanned_ports` minus `open_ports`, computed at read time.

Rejected alternatives:

- A `sweep_host_port_results` child table multiplies row count by ports per
  host per execution. For a group sweeping a /16 on three ports hourly this is
  a large table to answer a question an array answers.
- A jsonb `port_results` blob preserves per-port timing and error text at the
  cost of TOAST pressure on a table that is already the largest sweep table,
  for detail no acceptance criterion asks for.

The issue phrases the requirement as one category, "closed/no-response". This
design does not distinguish RST-refused from timed-out. That distinction is not
present in the persisted payload shape and would require an agent-side change;
it is deliberately out of scope.

### Rollup: a daily Oban worker, not a continuous aggregate

`sweep_host_results` is not a hypertable. A Timescale continuous aggregate
would require converting a live, foreign-keyed table, which is a materially
riskier change than a scheduled job, and buys nothing for a rollup that
refreshes once a day.

The worker mirrors `sweep_data_cleanup_worker`: daily, idempotent, string-keyed
args, batched. It is scheduled to run before cleanup, so a day's raw rows are
always rolled up before they are eligible for deletion. Because the upsert is
idempotent on the grain key, a re-run or a retry cannot double-count.

Grain: `(day, device_uid, ip, sweep_group_id, agent_id)`. That grain is what
makes overlap answerable long after the raw rows expire: two rows sharing a day,
device and agent but differing in sweep group is exactly the overlap case, and
it survives in the rollup where `device_agent_availability` would have kept only
the last writer.

### Compiled config: allowlist, not filter

`agent_config_versions.compiled_config` holds output from every compiler.
`snmp_compiler.ex` and `mapper_compiler.ex` both place credential material
there, so the table cannot be exposed as an SRQL entity.

`sweep_compiled_config` therefore selects named columns only: sweep group id and
name, profile id, ports, modes, interval, enabled, and compiled scan settings.
The `compiled_config` jsonb is never projected, so there is no blob for a future
compiler to hide a secret inside.

An allowlist is chosen over a denylist because a denylist must be updated every
time a compiler adds a field, and fails open when someone forgets. An
integration test asserts the entity's exposed column set equals the allowlist
exactly, so widening the projection turns a gate red rather than silently
publishing a new field.

`sweep_profiles` exposes banner grab as `enabled` and `protocols` only. Banner
grab writes are gated on `networks.sweeps.banner_grab`; reads through SRQL are
not, and the timeout, concurrency and rate knobs have no diagnostic value here.

Banner content itself was audited and is safe: `banner_grab_summary` on
executions holds counters only, with an existing regression test refuting an
attacker-controlled key surviving into it, and raw `banner_bytes` exists only in
the netprobe proto, never as a database column.

### Authorization

An earlier draft of this design claimed SRQL had no per-entity RBAC gate and
that `fix-srql-query-rbac-catalog` was unimplemented. Both claims were wrong.
`ServiceRadarWebNG.SRQL.EntityAccess` exists and is live, mapping `in:<entity>`
to an RBAC catalog key and returning `{:error, :forbidden}`. It is called from
`Api.Access.execute_query/2`, which is the path HTTP `POST /api/query` and MCP
`execute_srql` both take.

Three consequences follow.

**Mapping is mandatory, not optional.** `entity_access_test.exs` fails when any
catalog entity other than `dashboards` has no permission mapping. An unmapped
entity is `:passthrough`, meaning allowed, so that test is the only thing
standing between a new entity and a silently ungated one. All seven sweep
entities must be added to `EntityAccess` in the same change that adds them to
the catalog. A second test asserts every catalog id parses through the Rust
parser, so the Elixir and Rust entity lists cannot drift.

**Gating `sweep_compiled_config` needs no new mechanism.** Add a permission to
the RBAC catalog with admin default roles and list the entity under that key.
`RoleProfileSeeder` re-syncs seeded profiles on boot, so there is no migration.
There is no admin-only view key for sweeps today: `settings.networks.manage` is
operator plus admin, so a new key is required rather than reused.

**The gate has a token-order hole that this change must close.**
`EntityAccess.extract_entity/1` anchors on `~r/^in:(\S+)/`, but the Rust parser
accepts `in:` at any token position and the grammar documentation states tokens
may appear in any order. `limit:1 in:sweep_compiled_config` therefore extracts
`"limit:1"`, matches no permission, and passes through ungated. This is a
pre-existing hole affecting every gated entity, not one this change introduces,
but an admin-only compiled-config entity whose gate is bypassed by reordering
two tokens is decorative. Closing it is a prerequisite here, not a nice-to-have.

For the detail-loader scope requirement, see the
[SRQL access contract](../../../docs/docs/rbac-and-roles.md#srql-and-detail-page-access).

### Query window versus rollup retention

`max_time_range_days_for_ast` caps any entity outside the hourly-CAGG allowlist
at 90 days. `sweep_coverage_daily` is retained for 400, so the entity would
reject exactly the historical queries it exists to serve. The cap must admit
`sweep_coverage` explicitly. This is a real behavior change to a shared limit
and is called out here rather than buried in the implementation.

## Risks

- Row width on `sweep_host_results` grows by one array plus two identity
  columns on the largest sweep table. Mitigated by the 7 day retention that
  already applies and by choosing arrays over jsonb.
- The rollup worker adds a daily scan of a week of host results. Batched, and
  scheduled adjacent to the cleanup worker that already scans the same rows.
