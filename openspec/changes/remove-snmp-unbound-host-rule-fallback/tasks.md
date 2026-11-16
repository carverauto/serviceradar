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

## 5. Follow-up: explicit targets on a host that belongs to a device

- [x] 5.1 Fail-first tests in `snmp_compiler_test.exs`: a device override beats
      a matching rule and the target's own credential; a matching rule beats
      the target's own credential; a target no rule selects is polled with its
      own credential, else its profile's, on a device or on no device
- [x] 5.2 `CredentialResolver.resolve_for_target/4` over the shared
      `resolve_for_devices/3` pipeline, the target and its profile as ordered
      fallbacks; delete `resolve_for_host/3`; the compiler takes the resolved
      credential whatever its source
- [x] 5.3 Read-only demo impact check: which explicit targets change
      credential, compared by credential identity without decrypting
- [x] 5.4 Docs: manual SNMP target credentials state the full order
