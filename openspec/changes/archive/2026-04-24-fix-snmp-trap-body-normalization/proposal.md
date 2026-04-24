# Change: Fix SNMP trap body normalization

## Why
Processed SNMP trap logs are currently persisting the NATS subject name `logs.snmp.processed` as the body instead of the trap message text. The built-in SNMP Zen rule only rewrites `body` when it is already the processed-subject sentinel or an empty string, so traps that arrive with a missing/null `body` fall through and trigger the DB writer's subject fallback.

The current default-rule seeding path also only inserts missing Zen rules. That means changing the built-in SNMP template alone would fix fresh installs but would leave existing deployments, including the current demo environment, on the broken compiled rule until someone edits the rule manually.

## What Changes
- Update the built-in SNMP Zen normalization expression so traps with a missing/null `body` derive their message body from trap varbind content.
- Reconcile existing built-in `snmp_severity` rules so stored compiled JDM picks up the corrected definition without manual database edits.
- Add regression coverage for the missing-body SNMP trap path in the built-in template/rule tests and downstream log persistence path.

## Impact
- Affected specs: `observability-signals`, `observability-rule-management`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/observability/zen_rule_templates.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/zen_rule_seeder.ex`
  - `build/packaging/zen/rules/snmp_severity.json`
  - `rust/consumers/zen/src/tests.rs`
  - `elixir/serviceradar_core/test/serviceradar/observability/zen_rule_templates_test.exs`
  - downstream SNMP log parsing/persistence tests as needed
