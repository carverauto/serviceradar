## 1. Implementation
- [x] 1.1 URL-encode admin API path parameters in the HTTP adapter.
- [x] 1.2 Refactor local admin user updates to apply atomically.
- [x] 1.3 Distinguish omitted `role_profile_id` from explicit profile removal.
- [x] 1.4 Clamp user list limits and accept integer limit inputs safely.

## 2. Verification
- [x] 2.1 Add or update focused tests for HTTP adapter path encoding.
- [x] 2.2 Add or update focused tests for atomic local user updates.
- [x] 2.3 Add or update focused tests for explicit role-profile clearing.
- [x] 2.4 Add or update focused tests for bounded/integer pagination limits.
- [ ] 2.5 Run `mix compile` in `elixir/web-ng` and the relevant focused `mix test` targets.
