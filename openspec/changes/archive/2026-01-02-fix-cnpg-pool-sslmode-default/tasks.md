## 1. Implementation
- [x] 1.1 Update `pkg/db/cnpg_pool.go:NewCNPGPool` to default `sslmode=verify-full` when `cfg.TLS != nil` and `cfg.SSLMode == ""`
- [x] 1.2 Add validation so `cfg.TLS != nil` + `cfg.SSLMode == "disable"` returns an error before dialing
- [x] 1.3 Ensure explicit `cfg.SSLMode` values (`require`, `verify-ca`, `verify-full`, etc.) are preserved (subject to validation)
- [x] 1.4 Add unit tests for defaulting and validation (no network required; validate connection string / config behavior)

## 2. Documentation
- [ ] 2.1 Update `openspec/specs/cnpg/spec.md` (via archive) to reflect secure defaults and validation rules
- [ ] 2.2 Add/adjust a short operator note in docs (if needed) describing `ssl_mode` override guidance for IP-based connections

## 3. Validation
- [x] 3.1 Run `openspec validate fix-cnpg-pool-sslmode-default --strict`
- [x] 3.2 Run relevant Go unit tests (targeted `go test ./pkg/db/...`)
