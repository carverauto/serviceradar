## 1. Implementation
- [ ] 1.1 Update the built-in SNMP normalization rule so missing/null, empty, and subject-placeholder bodies all derive from trap varbind text.
- [ ] 1.2 Reconcile existing default `snmp_severity` Zen rules so current deployments receive the corrected compiled JDM without manual edits.
- [ ] 1.3 Add regression tests for the missing-body SNMP trap path in the built-in rule/template coverage and the persisted log body path.

## 2. Validation
- [ ] 2.1 Run the relevant Elixir and Rust tests covering SNMP Zen rule compilation/evaluation and log persistence.
- [ ] 2.2 Run `openspec validate fix-snmp-trap-body-normalization --strict`.
