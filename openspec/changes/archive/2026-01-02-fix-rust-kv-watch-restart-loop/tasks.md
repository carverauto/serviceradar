## 1. Implementation
- [x] 1.1 Add `is_initial` guard to flowgger's KV watch loop in `cmd/flowgger/src/main.rs`
- [x] 1.2 Add `is_initial` guard to trapd's KV watch loop in `cmd/trapd/src/main.rs`
- [x] 1.3 Add `is_initial` guard to sysmon's KV watch loop in `cmd/checkers/sysmon/src/main.rs`
- [x] 1.4 Add `is_initial` guard to rperf-client's KV watch loop in `cmd/checkers/rperf-client/src/main.rs`
- [x] 1.5 Verify flowgger starts and stays running in docker compose without restart loops
- [x] 1.6 Verify syslog messages can be sent to flowgger on port 514
