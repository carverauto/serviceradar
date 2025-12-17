# Change: Fix `cloneDeviceRecord` metadata aliasing for empty maps

## Why
Issue #2145 reports that `pkg/registry/device_store.go:cloneDeviceRecord` fails to deep-copy `DeviceRecord.Metadata` when the source map is empty-but-non-nil. Because the record is shallow-copied (`dst := *src`), the clone and original end up sharing the same underlying map reference, defeating the defensive-copying contract used throughout the device registry.

This can cause surprising cross-call contamination (a later clone “inherits” keys written to a previous clone), incorrect device state in the registry’s in-memory cache, and potential data races when callers concurrently read/write “independent” record copies.

## What Changes
- Update `cloneDeviceRecord` to deep-copy `Metadata` when `src.Metadata != nil` (including empty maps).
- Update `cloneDeviceRecord` to deep-copy `DiscoverySources` and `Capabilities` when non-nil (including empty-but-non-nil slices) to avoid similar aliasing via shared backing arrays.
- Add regression tests covering:
  - Empty-but-non-nil `Metadata` map isolation (original vs clone and clone vs clone).
  - Empty-but-non-nil slices with non-zero capacity (append to clone does not affect original or subsequent clones).

## Impact
- Affected specs: `device-registry-defensive-copying`
- Affected code:
  - `pkg/registry/device_store.go` (`cloneDeviceRecord`)
  - `pkg/registry/*_test.go` (new/updated unit tests)
- Risk: Low. Changes are limited to defensive copying; primary impact is small additional allocations during record cloning.

