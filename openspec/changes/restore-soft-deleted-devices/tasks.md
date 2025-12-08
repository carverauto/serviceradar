## 1. Implementation
- [x] 1.1 Update CNPG device upsert to clear `_deleted`/`deleted` when processing non-deletion updates so churned devices reanimate (`pkg/db/cnpg_unified_devices.go`).
- [x] 1.2 Add regression test asserting that a non-deletion update removes `_deleted` while explicit deletion updates keep it set (`pkg/db/cnpg_unified_devices_test.go`).
- [x] 1.3 Validate demo CNPG counts return to ~50k active devices after deploy (non-deleted count matches faker total).

## 2. Verification
- [ ] 2.1 `openspec validate restore-soft-deleted-devices --strict`
- [x] 2.2 `go test` for updated DB upsert logic
- [x] 2.3 Manual DB query in demo: `select count(*) from unified_devices where coalesce(lower(metadata->>'_deleted'),'false') <> 'true';` (observed 50,003)
- [ ] 2.4 Registry consistency check: registry-backed inventory should match CNPG counts; currently ~45–48k via registry versus 50k in CNPG/SRQL (investigation pending).
