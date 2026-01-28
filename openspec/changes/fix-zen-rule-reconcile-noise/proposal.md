# Change: Reduce zen rule reconcile noise and add resilience

## Why
Zen rule reconciliation logs repeated warnings without clear context, making it hard to diagnose real failures and adding noise during startup or datasvc interruptions.

## What Changes
- Classify transient datasvc sync failures during reconciliation and avoid per-rule warning spam.
- Emit a single reconcile summary with counts and include rule identifiers + reasons on actionable failures.
- Add tests to validate reconcile logging behavior for transient failures and real errors.

## Impact
- Affected specs: observability-rule-management
- Affected code: core-elx zen rule reconcile sync (`elixir/serviceradar_core/lib/serviceradar/observability/zen_rule_sync.ex`)
