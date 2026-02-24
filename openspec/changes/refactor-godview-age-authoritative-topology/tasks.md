## 1. Backend Canonical Contract
- [ ] 1.1 Define canonical directional edge contract for GodView in core/AGE projection layer.
- [ ] 1.2 Ensure mapper evidence ingestor persists enough data to derive `if_index_ab` and `if_index_ba` deterministically.
- [ ] 1.3 Implement reconciler-owned edge selection (protocol/confidence arbitration) before AGE upsert.
- [ ] 1.4 Expose canonical AGE edge query endpoint/stream payload with directional telemetry fields and `telemetry_eligible`.

## 2. Frontend De-scope
- [ ] 2.1 Remove frontend pair-candidate selection and protocol arbitration from GodView topology build path.
- [ ] 2.2 Remove frontend interface-attribution inference for directional telemetry; consume backend fields only.
- [ ] 2.3 Keep frontend clustering/rendering only (no topology inference semantics).

## 3. Verification and Safety
- [ ] 3.1 Add backend integration tests for canonical edge selection across LLDP/CDP/SNMP-L2/UniFi evidence mixes.
- [ ] 3.2 Add regression tests for directional telemetry parity (`ab/ba`) from AGE output to Arrow payload.
- [ ] 3.3 Add cutover metrics/SLO checks (edge count parity, unresolved edge count, animated-edge parity).
- [ ] 3.4 Run `openspec validate refactor-godview-age-authoritative-topology --strict`.
