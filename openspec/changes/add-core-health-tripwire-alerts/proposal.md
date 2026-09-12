# Change: Alert on core health checks that go unhealthy

## Why

The three anomaly-pipeline tripwires (`seasonal-baseline-freshness`,
`anomaly-ingest-silence`, `anomaly-alert-liveness`) and, since
`fix-anomaly-baseline-delivery-and-capacity-runway`, the baseline producer's
partial-delivery heartbeat all record `core` health events. Nothing alerts on
them: the internal `health.state_change` log is stored with only ingest
metadata as attributes, no event rule promotes it, and no stateful rule
matches it. The seasonal-baseline freshness check sat unhealthy on demo from
2026-07-18 to 2026-09-11 and produced zero alerts.

## What Changes

- The health log writer adds a nested `health` attribute block (entity type,
  entity id, old state, new state, reason) to the internal log payload, so the
  stored log row carries matchable, groupable fields.
- A seeded event rule promotes `logs.internal.health` logs whose entity type is
  `core` into `health.core.state_change` events (no direct alert).
- A seeded managed stateful rule opens one critical incident per
  `health.entity_id` when a core check transitions to unhealthy and recovers
  when it transitions back to healthy.
- Operator docs list the alert next to the tripwires it covers.

## Impact

- Affected specs: `health-events`
- Affected code: `elixir/serviceradar_core/lib/serviceradar/events/health_writer.ex`,
  `elixir/serviceradar_core/lib/serviceradar/observability/rule_seeder.ex`,
  `docs/docs/anomaly-detection.md`
- No schema change. The rule seeder creates the two rules on the next boot;
  existing operator-customized rules are untouched.
