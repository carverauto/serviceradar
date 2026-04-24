## 1. Implementation
- [x] 1.1 Add a shared secure temp capture helper for core-elx camera relay modules.
- [x] 1.2 Refactor the external boombox analysis worker to use secure temp allocation and cleanup for relay-derived H264 payloads.
- [x] 1.3 Refactor the boombox sidecar default output path to use the shared secure temp helper.
- [x] 1.4 Add or update focused tests for secure temp path handling in both boombox capture paths.

## 2. Validation
- [ ] 2.1 Run `cd elixir/serviceradar_core_elx && mix test test/serviceradar_core_elx/camera_relay`.
- [x] 2.2 Run `openspec validate harden-core-elx-boombox-tempfile-handling --strict`.
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`.
