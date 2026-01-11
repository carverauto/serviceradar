## 1. Fix cloning behavior
- [x] 1.1 Update `cloneDeviceRecord` to deep-copy `Metadata` for any non-nil map (even when empty)
- [x] 1.2 Update `cloneDeviceRecord` to deep-copy `DiscoverySources` and `Capabilities` for any non-nil slice (even when empty)
- [x] 1.3 Ensure pointer fields (`Hostname`, `MAC`, `IntegrationID`, `CollectorAgentID`) remain non-aliased as today

## 2. Add regression tests
- [x] 2.1 Add unit test: empty-but-non-nil `Metadata` is deep-copied (mutating clone does not affect original)
- [x] 2.2 Add unit test: two clones from the same record do not share `Metadata` (mutating one does not affect the other)
- [x] 2.3 Add unit test: empty-but-non-nil slices (including `make([]string, 0, N)`) do not alias (appending to clone does not affect original or later clones)

## 3. Verification
- [x] 3.1 Run `go test ./pkg/registry/...`
- [x] 3.2 Run `go test -race ./pkg/registry/...` (or a targeted race repro test if needed)
