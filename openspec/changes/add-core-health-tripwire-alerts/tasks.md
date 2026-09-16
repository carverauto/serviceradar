## 1. Health log attributes
- [x] 1.1 `HealthWriter.payload/1` (public) adds `attributes.health` with entity_type, entity_id, old_state, new_state, reason; unit test on the payload shape and severity mapping.

## 2. Seeded rules
- [x] 2.1 `RuleSeeder.default_event_rules/0` (public) gains `core_health_state_change_events`: `logs.internal.health` + `health.entity_type == core` -> `health.core.state_change`, `alert: false`.
- [x] 2.2 `RuleSeeder.default_stateful_rules/0` gains managed `core_health_check_unhealthy`: match unhealthy, recover on healthy, `group_by: ["health.entity_id"]`, critical.
- [x] 2.3 Rule matcher tests: unhealthy promoted event matches, healthy recovers, incident group is the check id; seeder integration test reads both rules back.

## 3. Docs and verification
- [x] 3.1 `docs/docs/anomaly-detection.md` names the alert under Silence Tripwires.
- [ ] 3.2 Post-deploy on demo: run the freshness worker over RPC with an empty heartbeat loader, confirm one critical alert opens for `seasonal-baseline-freshness`, run it normally, confirm the alert resolves.
