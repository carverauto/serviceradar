## 1. Design
- [x] 1.1 Define sweep host eligibility rules for mapper promotion
- [x] 1.2 Define mapper job selection rules for promoted hosts
- [x] 1.3 Define dedupe / cooldown behavior for repeated sweep hits

## 2. Implementation
- [x] 2.1 Add promotion orchestration to sweep result ingestion for eligible live hosts
- [x] 2.2 Reuse mapper command-bus dispatch to trigger on-demand discovery with promoted targets
- [x] 2.3 Persist promotion state / reason codes needed for idempotency and operator visibility
- [x] 2.4 Emit logs or telemetry for promoted, skipped, and suppressed hosts

## 3. Validation
- [x] 3.1 Add tests covering eligible host promotion
- [x] 3.2 Add tests covering duplicate suppression / cooldown behavior
- [x] 3.3 Add tests covering mapper job selection and failure paths
