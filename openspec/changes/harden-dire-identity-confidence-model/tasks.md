## 1. Specification and Policy
- [ ] 1.1 Finalize promotion and merge eligibility matrix (strong, medium, weak evidence classes)
- [ ] 1.2 Define deterministic canonical selection and conflict tie-break rules
- [ ] 1.3 Define provisional device lifecycle and state transitions

## 2. DIRE Implementation
- [ ] 2.1 Refactor identity reconciliation to consume evidence classes instead of raw identifier type alone
- [x] 2.2 Enforce merge gate: no MAC-only auto-merge
- [x] 2.3 Enforce promotion gate: weak evidence requires corroboration and repeated sightings
- [x] 2.4 Ensure blocked merge paths preserve stable canonical IDs and emit structured logs
- [x] 2.5 Add/extend telemetry counters for promoted evidence, blocked merges, and manual override merges

## 3. Mapper / Discovery Pipeline
- [x] 3.1 Stop direct promotion of interface MAC observations into canonical identifiers
- [ ] 3.2 Persist interface/neighbor observations as evidence only
- [x] 3.3 Ensure mapper-created devices are marked/handled as provisional until promotion criteria are met
- [x] 3.4 Implement role inference (`router`, `ap_bridge`, `switch_l2`, `host`, `unknown`) with confidence scoring from mapper/SNMP signals
- [x] 3.5 Apply role-aware alias policy:
- [x] 3.5.a router keeps self-interface IP aliases
- [x] 3.5.b ap/bridge/switch_l2 blocks client-like interface IP aliases
- [x] 3.6 Emit filtered AP/bridge client IP observations as endpoint discovery candidates
- [x] 3.7 Add operator-visible metadata fields (`device_role`, `device_role_confidence`, `device_role_source`)

## 4. Data and Migration
- [ ] 4.1 Add migrations/resources for evidence state if required
- [ ] 4.2 Backfill existing records to new classification model
- [ ] 4.3 Add rollback-safe migration plan and runbook notes

## 5. Test Matrix (Required)
- [ ] 5.1 Unit tests for evidence classification (global MAC, local MAC, agent ID, serial, integration IDs)
- [x] 5.2 Unit tests for merge gating (MAC-only blocked, mixed-strong allowed)
- [x] 5.3 Unit tests for promotion gating (single-sighting blocked, corroborated promotion allowed)
- [ ] 5.4 Integration tests for mapper reorder/noise scenarios (stable canonical outcome)
- [ ] 5.5 Integration tests for sweep + mapper interleaving order invariance
- [ ] 5.6 Integration tests for alias-state interactions under strict merge policy
- [ ] 5.7 Regression tests for issue #2780/#2817 scenarios (farm01/tonka01 class)
- [ ] 5.8 Property/fuzz-style tests for ingestion order permutations and idempotence
- [x] 5.9 Router alias preservation tests (tonka-style multi-interface L3 aliases)
- [x] 5.10 AP/bridge client-IP pollution prevention tests (client IPs not promoted as aliases)
- [x] 5.11 AP/bridge filtered client-IP promotion tests (candidate device creation path)

## 6. Validation and Rollout
- [ ] 6.1 Run focused Elixir test suites for inventory and mapper flows
- [x] 6.2 Validate OpenSpec deltas with `openspec validate harden-dire-identity-confidence-model --strict`
- [ ] 6.3 Demo/staging verification using CNPG queries and merge_audit drift checks
- [ ] 6.4 Phased rollout: classify/log-only -> enforce role-aware alias policy -> enable candidate promotion
