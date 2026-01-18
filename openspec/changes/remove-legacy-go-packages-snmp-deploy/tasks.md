## 1. Implementation
- [x] 1.1 Inventory usages of `pkg/identitymap`, `pkg/http`, `pkg/db`, `pkg/sync`, `pkg/registry` and confirm safe removal.
- [x] 1.2 Remove dead packages and update imports/usages or delete now-unused code paths.
- [x] 1.3 Remove standalone SNMP checker build targets (Go/Bazel/Docker) and any packaging references.
- [x] 1.4 Update Helm charts and Docker Compose to drop SNMP checker services/values.
- [x] 1.5 Update docs/references mentioning standalone SNMP checker or removed packages.
- [ ] 1.6 Run formatting/linting/tests for touched components.
- [ ] 1.7 Verify builds no longer produce SNMP checker images and clean up artifacts.
- [ ] 1.8 Close issues #2308, #2306, #2305, #2304, #2303 after validation.
