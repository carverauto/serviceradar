# Change: Stateful Alert Rule Engine with Durable Windows

## Why
Operators need stateful alert rules (for example, "5 failures in 10 minutes") that
survive service restarts without exploding database size or creating duplicate
alerts.

## What Changes
- Add per-tenant stateful alert rules with configurable group-by keys (defaulting
  to integration source id).
- Implement a bucketed ERTS rule engine with ETS-backed windows and durable state
  snapshots flushed per bucket.
- Record rule evaluation history with bounded retention and compression so CNPG
  does not grow unbounded.
- Add cooldown and re-notify behavior for long-lived incidents.

## Impact
- Affected specs: observability-signals, cnpg
- Affected code: core-elx rule engine, observability/log promotion pipeline,
  tenant migrations for rule state/history storage
