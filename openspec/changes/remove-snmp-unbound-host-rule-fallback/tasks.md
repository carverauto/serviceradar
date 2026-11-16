## 1. Resolution

- [x] 1.1 Fail-first tests in `snmp_compiler_test.exs`: two rules on one agent
      with different target queries; an explicit target on a host no device
      holds gets neither rule and, without a credential of its own, compiles no
      target and is reported; with its own credential it is polled with that;
      a host whose device a rule selects is polled with the rule
- [x] 1.2 `CredentialResolver.resolve_for_host/3`: an unbound host resolves to
      no credential; delete `resolve_unbound_host/2` and
      `resolve_unscoped_rule_credential/2`; expose `device_uid_for_host/2`

## 2. Reporting

- [x] 2.1 `SNMPCompiler`: telemetry `[:serviceradar, :snmp,
      :target_without_credential]` per compile and a warning-ledger log line
      for an explicit target with no usable credential
- [x] 2.2 Settings: "No credential" badge on a legacy manual target that names
      no credential of its own

## 3. Migration

- [x] 3.1 Migration enqueueing `SNMPTargetCredentialBackfillWorker` once;
      Helm `core.migrations.expectedVersion` bumped
- [x] 3.2 Worker with `plan/0` and `run/0`; tests for bind, agents disagree,
      and targets decided by their own credential or their device

## 4. Validation

- [x] 4.1 Focused DB tests on a srql-fixtures scratch database
- [x] 4.2 `openspec validate remove-snmp-unbound-host-rule-fallback --strict`
