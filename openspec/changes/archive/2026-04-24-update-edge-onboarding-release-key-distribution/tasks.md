## 1. Implementation
- [x] 1.1 Add runtime configuration in `web-ng` for `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` so edge onboarding can read the configured verification key.
- [x] 1.2 Update agent-capable onboarding bundle generation to emit the standard overrides file containing `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` when the key is configured.
- [x] 1.3 Update the agent enrollment flow to install or update the packaged-agent overrides file from the onboarding bundle without disturbing other overrides.
- [x] 1.4 Add focused tests for bundle generation and enrollment persistence of the release verification key.
- [x] 1.5 Update onboarding and release-management docs to describe how the public key is supplied and propagated.

## 2. Validation
- [x] 2.1 Run `openspec validate update-edge-onboarding-release-key-distribution --strict`.
- [ ] 2.2 Run targeted `web-ng` and Go onboarding tests covering the new key distribution path.
