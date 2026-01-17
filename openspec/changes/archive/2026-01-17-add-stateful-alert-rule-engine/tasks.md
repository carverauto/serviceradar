## 1. Implementation
- [x] 1.1 Define Ash resources for stateful alert rules, rule state snapshots, and evaluation history
- [x] 1.2 Add tenant migrations for rule state and rule evaluation history (hypertable + retention/compression)
- [x] 1.3 Implement bucketed rule engine (ETS + per-bucket flush) with per-tenant partitioning
- [x] 1.4 Add cooldown and re-notify handling when alerts remain active
- [x] 1.5 Wire rule engine to log/event inputs and alert creation pipeline
- [x] 1.6 Add cleanup jobs for idle rule state (TTL) and validate retention policies
- [x] 1.7 Add tests for rule evaluation, restart recovery, and cooldown behavior
- [x] 1.8 Shift rule evaluation to OCSF event ingestion (log promotion + event writer)
