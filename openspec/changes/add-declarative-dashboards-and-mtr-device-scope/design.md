# Design

## D1: JSON, not YAML

The definition is JSON. The deciding factor is that the payload is already JSON:
`DashboardPanel` stores `data_binding`, `display_config`, `visual_config`,
`layout` and `builder_state` as `:map` attributes, and `AuthoredDashboard` stores
`layout`, `variables` and `metadata` the same way. Serializing a dashboard is
therefore close to dumping those maps, and import is close to feeding them back
to the create actions. A YAML layer would add a dependency web-ng does not have
today plus a conversion step, for ergonomics that matter only when
hand-authoring — and the premise of this change is that the **builder** is the
author.

Nothing prevents a YAML front end later; it would parse to the same document.

### Shape

One file per dashboard, holding a version, the dashboard's own fields, and an
ordered list of panels. Panel entries carry exactly the fields the resource
accepts, including `layout`, so a definition fully determines what renders.

The version is mandatory and checked on import. An unknown version is refused
with a message naming the file, not skipped: a definition the loader silently
ignores is indistinguishable from one that was never shipped.

## D2: Import creates, and never rewrites

Import is create-when-absent, matched by slug. It does not reconcile.

This is the earned part of the design. The previous `SystemReports` reconciled
drifted fields via `maybe_put/4`, which wrote the shipped constant back whenever
the stored value differed — so an operator who edited a built-in dashboard's query
had it restored on the next boot, with nothing to indicate why. The divergence
appeared long after the edit had apparently succeeded, which is what made it
expensive.

The single exception is a dashboard row carrying zero panels. That is an
interrupted creation, not a configuration anyone chose through the builder, so its
panels may be created.

**The consequence is deliberate and should be stated plainly:** improvements to a
shipped dashboard do not reach an installation where an operator has edited it.
That is the correct trade — silently discarding operator work to deliver a better
default is worse than shipping a stale default. If targeted updates are wanted
later, the mechanism must distinguish "untouched since import" from "customised",
and must fail closed toward keeping operator state.

## D3: Export is the inverse of import, and is tested as such

Export writes the same format import reads. The property that matters is
round-trip: exporting a dashboard and importing it into an empty database yields a
dashboard equivalent over the fields the format defines.

Asserting this is the point. Export and import drifting apart is the likely
failure, and it is invisible until someone tries to move a dashboard between
installations and finds a panel missing a binding. The test is a real round trip
against the fixture database, not a comparison of two hand-written fixtures.

Fields outside the format — database ids, timestamps, `dashboard_ref`, ownership,
access grants — are explicitly out of scope and named in the spec, so "equivalent"
has a definition rather than being a judgement call.

## D4: `target_ip` is the attribution key; `device_id` is not sufficient

Both columns are added to `mtr_hops`, but the dashboard filters on `target_ip`.

On the bulk-scheduled path a trace's `device_id` holds the **command** id rather
than a device uid. A dashboard grouping by `device_id` would therefore produce one
row per bulk command, which looks like data and answers nothing. The existing
device-details MTR tab already matches on `target_ip` for exactly this reason.

`device_id` is still carried because on the single-run path it is a real device
uid and is the more precise key when present. The spec states which is reliable so
a future panel does not pick the wrong one.

### Backfill

`mtr_hops` is a TimescaleDB hypertable. The backfill is therefore chunk-aware and
batched, not one `UPDATE`: a single statement across all chunks on a large
installation is the shape that exhausts memory and gets a node OOM-killed. Where
compression is enabled, compressed chunks must be handled explicitly rather than
failing mid-migration.

Backfill is idempotent and resumable — it must be safe to run again after an
interruption, because on a large table it will be interrupted.

## D5: `stats:` on `mtr_traces` answers a different question

Removing the rejection is not symmetry for its own sake. Trace-level aggregation
yields reach rate per target, from `target_reached` and trace counts, which is the
**endpoint** signal: which devices are not reached at all. Hop-level data cannot
express it, because a trace that never reaches its target has no terminal hop to
measure.

Together the two give the diagnostic split this change exists for — a shared
upstream fault shows as loss concentrated at one hop address traversed by many
traces, while individually unreachable endpoints show as low reach rate spread
across targets with clean upstream hops.

## D6: Panels must not present ICMP rate limiting as loss

Mid-path routers deprioritize their own ICMP replies and report loss they are not
causing. A panel ranking hop addresses by loss therefore surfaces rate-limiting
routers above real faults, and the flat fleet-wide figure the current dashboard
draws is dominated by that artifact.

Two mitigations are expressible today and are required:

- Break loss down **by hop position**, so loss that begins at a position and
  continues is distinguishable from loss at one position only.
- Report a **trace count** beside each hop address, so a hop traversed by many
  traces is distinguishable from one seen twice.

The definitive test — whether loss at a hop persists to subsequent hops — needs a
self-join across hop positions that SRQL cannot express. It is out of scope here,
and the spec says so rather than implying the panels settle it. `mtr_data.ex`
already computes terminal-hop loss correctly via a `ROW_NUMBER` CTE for the
existing diagnostics pages, which remains the place to confirm a finding.

## Open gates

- Whether compression is enabled on `mtr_hops` in any deployed installation, which
  determines how much compressed-chunk handling the backfill needs. Locally it is
  off.
- Whether export should include access grants and report schedules. Excluded here
  because they reference principals that may not exist in the importing
  installation, but an operator moving a dashboard between environments may expect
  them.
- Whether the definition directory is read from `priv/` at runtime or embedded at
  compile time. Runtime keeps a definition editable in a release; compile-time
  would need `@external_resource` per the repository's Elixir rules.
