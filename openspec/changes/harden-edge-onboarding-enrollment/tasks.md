## 1. Implementation
- [x] 1.1 Add integrity protection for structured onboarding tokens and reject tampered `edgepkg-v2` tokens during enrollment.
- [x] 1.2 Update token generation in `web-ng` to emit the hardened token format and keep compatibility behavior explicit for existing/manual workflows.
- [x] 1.3 Remove insecure transport support from `serviceradar-cli enroll`.
- [x] 1.4 Require HTTPS for all remote onboarding bundle downloads.
- [x] 1.5 Add targeted tests for token tampering rejection, secure defaults, and HTTPS enforcement.
- [x] 1.6 Update onboarding documentation to describe the new trust model and any rollout/migration implications.

## 2. Validation
- [x] 2.1 Run `openspec validate harden-edge-onboarding-enrollment --strict`.
- [x] 2.2 Run targeted Go tests for `edgeonboarding` and CLI enrollment behavior.
- [x] 2.3 Run targeted `web-ng` tests or compile checks covering token generation changes.
