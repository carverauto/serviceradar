## 1. Implementation
- [x] 1.1 Remove query-param token fallback from edge package and collector package POST delivery endpoints.
- [x] 1.2 Remove query-param token fallback from plugin blob POST download/upload endpoints.
- [x] 1.3 Use operator-configured canonical base URLs for onboarding bundle generation instead of request host data.
- [x] 1.4 Update docs and generated command expectations for the stricter token transport rules.

## 2. Verification
- [ ] 2.1 Run focused edge-onboarding, collector, and plugin delivery tests.
- [x] 2.2 Run `openspec validate remove-post-query-token-fallbacks-and-pin-bundle-base-url --strict`.
