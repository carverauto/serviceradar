## 1. Pipeline Boundaries
- [x] 1.1 Implement staged worker lifecycle boundaries with explicit phase transitions.
- [x] 1.2 Enforce identity phase completion before topology relationship resolution.

## 2. Performance and Contracts
- [x] 2.1 Replace per-target expensive host probing with shared reusable workers/services.
- [x] 2.2 Replace untyped/raw result dumping with structured discovery payload contracts.

## 3. Verification
- [x] 3.1 Add regression tests for phase ordering and non-collapse identity behavior.
- [x] 3.2 Add performance comparison checks for high-target discovery runs.
- [x] 3.3 Run `openspec validate refactor-mapper-discovery-pipeline-boundaries --strict`.
