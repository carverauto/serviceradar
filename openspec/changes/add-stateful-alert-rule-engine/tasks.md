## 1. Implementation
- [ ] 1.1 Define Ash resources for stateful alert rules, rule state snapshots, and evaluation history
- [ ] 1.2 Add tenant migrations for rule state and rule evaluation history (hypertable + retention/compression)
- [ ] 1.3 Implement bucketed rule engine (ETS + per-bucket flush) with per-tenant partitioning
- [ ] 1.4 Add cooldown and re-notify handling when alerts remain active
- [ ] 1.5 Wire rule engine to log/event inputs and alert creation pipeline
- [ ] 1.6 Add cleanup jobs for idle rule state (TTL) and validate retention policies
- [ ] 1.7 Add tests for rule evaluation, restart recovery, and cooldown behavior
