## 1. Implementation
- [ ] 1.1 Add `disk_exclude_paths` to sysmon config (proto/agent config/Ash resource) with default empty list.
- [ ] 1.2 Update sysmon collector to treat empty `disk_paths` as collect-all and apply excludes.
- [ ] 1.3 Update sysmon profile compiler and agent config generator defaults to use collect-all behavior.
- [ ] 1.4 Update default sysmon profile in the tenant schema (backfill existing default profiles).
- [ ] 1.5 Update sysmon settings UI to expose disk excludes and clarify defaults.
- [ ] 1.6 Add tests for collect-all + exclude behavior and default profile updates.
