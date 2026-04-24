## 1. Implementation
- [x] 1.1 Remove request-derived base URL generation from admin edge package and collector LiveViews.
- [x] 1.2 Use canonical configured endpoint URLs for copied bootstrap commands and onboarding token encoding.
- [x] 1.3 Include explicit `--core-url` in copied agent enroll commands.
- [x] 1.4 Update focused tests and docs.

## 2. Verification
- [ ] 2.1 Run focused bootstrap command and onboarding token tests.
- [x] 2.2 Run `openspec validate pin-admin-bootstrap-urls-to-configured-endpoints --strict`.
