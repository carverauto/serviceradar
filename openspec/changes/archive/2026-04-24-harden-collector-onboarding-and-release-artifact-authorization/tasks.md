## 1. Implementation
- [x] 1.1 Add signed collector enrollment tokens or equivalent integrity protection for collector token metadata.
- [x] 1.2 Remove unsigned agent and collector token parsing paths so only signed formats are accepted.
- [x] 1.3 Bind gateway-served release artifact authorization to the authenticated caller identity, not only `target_id` and `command_id`.
- [x] 1.4 Reject release artifact requests when the caller identity does not match the rollout target's intended agent.
- [x] 1.5 Update any generated install or operator workflows affected by the collector token hardening.
- [x] 1.6 Add targeted tests for collector token tampering, signed-only parsing behavior, and release artifact identity authorization.
- [x] 1.7 Update docs to reflect the new trust and authorization requirements.

## 2. Validation
- [x] 2.1 Run `openspec validate harden-collector-onboarding-and-release-artifact-authorization --strict`.
- [x] 2.2 Run targeted Go tests for collector onboarding and related CLI behavior.
- [x] 2.3 Run targeted Elixir tests or compile checks for gateway artifact authorization changes.
