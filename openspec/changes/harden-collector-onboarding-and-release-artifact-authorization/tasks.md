## 1. Implementation
- [ ] 1.1 Add signed collector enrollment tokens or equivalent integrity protection for collector token metadata.
- [ ] 1.2 Remove trust in unsigned collector token `BaseURL` values and require a separately trusted Core API URL for legacy compatibility flows.
- [ ] 1.3 Bind gateway-served release artifact authorization to the authenticated caller identity, not only `target_id` and `command_id`.
- [ ] 1.4 Reject release artifact requests when the caller identity does not match the rollout target's intended agent.
- [ ] 1.5 Update any generated install or operator workflows affected by the collector token hardening.
- [ ] 1.6 Add targeted tests for collector token tampering, legacy compatibility behavior, and release artifact identity authorization.
- [ ] 1.7 Update docs to reflect the new trust and authorization requirements.

## 2. Validation
- [ ] 2.1 Run `openspec validate harden-collector-onboarding-and-release-artifact-authorization --strict`.
- [ ] 2.2 Run targeted Go tests for collector onboarding and related CLI behavior.
- [ ] 2.3 Run targeted Elixir tests or compile checks for gateway artifact authorization changes.
