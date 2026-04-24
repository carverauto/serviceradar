## 1. Implementation
- [x] 1.1 Replace manual YAML string escaping with safe scalar encoding in edge bundle generation.
- [x] 1.2 Normalize and safely encode OTel collector port overrides.

## 2. Verification
- [x] 2.1 Add focused tests for YAML string encoding hardening.
- [x] 2.2 Add focused tests for OTel TOML port override hardening.
- [ ] 2.3 Run `mix compile` in `elixir/web-ng` and the focused `mix test` targets.
