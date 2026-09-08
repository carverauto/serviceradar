## 1. Implementation
- [ ] 1.1 Add Helm values to control the migration job (enabled flag, hook type/weight, and resources).
- [ ] 1.2 Add a Helm hook Job that runs public + tenant migrations using the core-elx release image.
- [ ] 1.3 Ensure the job uses the same DB/SPIFFE env and service account as core-elx.
- [ ] 1.4 Update Helm README/runbook docs with migration job behavior and disable/override options.
- [ ] 1.5 Add a smoke test or template check to ensure the hook renders correctly.
