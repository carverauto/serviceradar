## 1. Implementation
- [x] 1.1 Update the AXIS plugin websocket event dial path to stop embedding credentials in the URL and use the structured header-bearing connect payload instead.
- [x] 1.2 Ensure AXIS event result/error surfaces do not include credential-bearing websocket URLs.
- [x] 1.3 Add focused tests covering credential-free websocket URLs and header-based auth for AXIS event collection.

## 2. Verification
- [x] 2.1 Run `go test ./go/cmd/wasm-plugins/axis`
- [x] 2.2 Run `openspec validate harden-axis-plugin-websocket-credential-handling --strict`
- [x] 2.3 Run `openspec validate add-repo-security-review-baseline --strict`
- [x] 2.4 Run `git diff --check`
