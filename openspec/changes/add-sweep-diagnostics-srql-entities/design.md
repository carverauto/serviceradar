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

SRQL has no per-entity RBAC gate today. `fix-srql-query-rbac-catalog` (GitHub
#4088) is an open, unimplemented proposal, so every entity is currently readable
by any caller who reaches the shared execute path. The seven entities added here
inherit that hole.

This change does not fix that gap, but it does not widen it silently either:
catalog keys for the new entities are defined here so they are mapped the moment
that change lands, and `sweep_compiled_config` is gated admin-only from the
start rather than waiting.

## Risks

- Row width on `sweep_host_results` grows by one array plus two identity
  columns on the largest sweep table. Mitigated by the 7 day retention that
  already applies and by choosing arrays over jsonb.
- The rollup worker adds a daily scan of a week of host results. Batched, and
  scheduled adjacent to the cleanup worker that already scans the same rows.
