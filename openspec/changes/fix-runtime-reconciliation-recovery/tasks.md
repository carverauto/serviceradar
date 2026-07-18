## 1. Credential reconciliation

- [x] 1.1 Add provider policy preflight before broker grant issuance
- [x] 1.2 Convert known Proxmox policy rejections into stable summary skip reasons
- [x] 1.3 Preserve unexpected reconciliation failures and telemetry
- [x] 1.4 Add regression coverage proving insecure rules issue no grants or assignments

## 2. Oban stale conflict recovery

- [x] 2.1 Replace the enum-unsafe bulk update with a locked schema update
- [x] 2.2 Return concrete recovery errors instead of swallowing exceptions
- [x] 2.3 Add a PostgreSQL integration regression for the platform job-state enum

## 3. Verification and rollout

- [x] 3.1 Run formatting, warnings-as-errors compilation, strict Credo, focused tests, and strict OpenSpec validation
- [ ] 3.2 Publish a feature branch and Forgejo PR
- [ ] 3.3 Verify demo reports zero failed Proxmox agents and no stale-conflict warning loop after release
