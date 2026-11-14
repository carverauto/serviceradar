# Tasks: fail-closed SNMPv3 and parameterized cold-tier secrets

- [x] 1. Spec (this change): proposal, design, spec deltas;
  `openspec validate fail-closed-snmpv3-and-cold-tier-secrets --strict`
  green. Checked pending deltas for repeated wording: none names these
  contracts.
- [x] 2. Fail-first regression tests (invented fixtures only): all six
  fail on the unfixed tree for the intended reason — `security_level/1`
  nil-refusal, Go `UNSPECIFIED` parse error, mapper tagged refusal +
  nil-omission, broker explicit-garbage error, compiler skip.
- [x] 3. Implement: Elixir refusal at `security_level/1` (nil, no default)
  + broker absent/invalid distinction + finalize error propagation +
  `to_mapper_credentials` tagged refusal + mapper-compiler skip/suppress +
  `valid_v3_secrets?` backstop; Go `protoToSNMPSecurityLevel` error on
  `UNSPECIFIED`/unmapped. Cold tier explicitly out of scope per user
  decision 2026-11-13 (drop the cold-tier half). SNMP area suites green
  (102 mix tests; Go agent/snmp + mapper USM green; 3 remaining Go
  failures verified identical on the untouched base).
- [ ] 4. Format + quality gates (`mix format`, `git diff --check`, Bazel
  `--config=remote` quality/test targets for the touched areas), then
  no-mistakes gate (reviewer not claude), PR, `--merge`.
- [ ] 5. Demo verification after rollout: no silent-downgrade evidence —
  SNMP compiles with no `noAuthNoPriv` surprises (spot-check a v3 target
  and refusal-warning counts).
  any logged statement.
