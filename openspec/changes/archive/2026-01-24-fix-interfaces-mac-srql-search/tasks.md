## 1. Implementation
- [x] 1.1 Normalize interface MAC filter values for SRQL (case-insensitive, separator-insensitive) and apply to equality/like operators.
- [x] 1.2 Ensure `%` wildcard patterns in MAC filters are preserved end-to-end through SRQL translation and execution.
- [x] 1.3 Add SRQL unit/integration tests for interface MAC filters (exact match and wildcard).
- [x] 1.4 Add a UI/regression test or guard in web-ng if query encoding needs adjustment to preserve `%`.
