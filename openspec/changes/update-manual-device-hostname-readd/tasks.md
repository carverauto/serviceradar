## 1. Implementation
- [x] 1.1 Add include-deleted lookup helpers for manual device UID, resolved IP, and hostname.
- [x] 1.2 Update manual device creation to restore/update existing matches before attempting a fresh insert.
- [x] 1.3 Merge distinct active duplicate matches when the resolved-IP record and hostname-only record both exist.
- [x] 1.4 Improve LiveView success messaging so restored/updated devices are not reported as failed creates.
- [x] 1.5 Add tests for hostname-only DNS re-add, soft-deleted restore, and duplicate merge/update behavior.
- [x] 1.6 Navigate to the saved device details page after manual add/re-add.

## 2. Validation
- [ ] 2.1 Run focused manual device and LiveView tests. Blocked locally: database unavailable at `localhost:5432`.
- [x] 2.2 Run `mix compile --warnings-as-errors` for web-ng.
