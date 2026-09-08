## 1. Deep-copy helpers
- [x] 1.1 Add `models.DeepCopyHostResult(*models.HostResult) models.HostResult` that deep-copies `PortResults`, `PortMap`, and `ICMPStatus`
- [x] 1.2 Ensure copied `PortMap` entries reference the same copied `PortResult` pointers as `PortResults` (no duplicated per-port objects)
- [x] 1.3 Add unit tests verifying copies do not alias source fields (`PortResults`, `PortMap`, `ICMPStatus`)

## 2. Apply deep-copy to `BaseProcessor` summaries
- [x] 2.1 Update `collectShardSummaries()` to append deep-copied `HostResult` values
- [x] 2.2 Update `processShardForSummary()` / `GetSummaryStream()` to send deep-copied `HostResult` values
- [x] 2.3 Add regression test reproducing issue #2148 and verifying `go test -race` passes

## 3. Apply deep-copy to `InMemoryStore` conversions
- [x] 3.1 Update `convertToSlice()` to use deep-copied `HostResult` values
- [x] 3.2 Update `buildSummary()` to use deep-copied `HostResult` values

## 4. Verification
- [x] 4.1 Run `go test -race ./pkg/sweeper -run TestGetSummary_ConcurrentReadsDoNotPanic`
- [x] 4.2 Run `go test ./pkg/...`
