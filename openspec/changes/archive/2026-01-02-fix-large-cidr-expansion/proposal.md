# Change: Fix large CIDR seed expansion for discovery

## Why
Large CIDR ranges (e.g. `/16`, `/8`) currently expand to a single repeated IP due to a loop variable bug in `pkg/mapper/utils.go` (GH issue #2146). This causes mapper discovery runs against large networks to effectively scan only one address.

## What Changes
- Fix `collectIPsFromRange` to increment and stringify the same IP value in the large-range path.
- Fix IPv4 network/broadcast filtering to avoid panics when `net.ParseCIDR` returns 16-byte IPv4 addresses.
- Add regression coverage for CIDR expansion behavior (large ranges are capped and produce multiple unique targets).
- Capture the intended CIDR expansion/limiting behavior in the `network-discovery` capability spec.

## Impact
- Affected specs: `network-discovery`
- Affected code: `pkg/mapper/utils.go`, `pkg/mapper/*_test.go`
- Operational impact: Large-CIDR discovery runs will return to scanning up to the configured cap (256) instead of a single IP.
