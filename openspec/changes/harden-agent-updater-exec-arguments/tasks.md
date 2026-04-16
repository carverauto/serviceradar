## 1. Implementation
- [x] 1.1 Add managed-release activation argument validation helpers for version, command ID, command type, and control-character rejection.
- [x] 1.2 Enforce those validations before spawning the updater process during managed release activation.
- [x] 1.3 Keep the updater activation command type restricted to the managed release command type set.
- [x] 1.4 Add focused Go tests for accepted activation arguments and the failure cases called out in SR-2026-002.

## 2. Validation
- [x] 2.1 Run focused Go tests for managed release activation and updater argument validation.
- [x] 2.2 Run `openspec validate harden-agent-updater-exec-arguments --strict`.
