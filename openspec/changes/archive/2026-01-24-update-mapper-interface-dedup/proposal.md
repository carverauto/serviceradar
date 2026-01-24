# Change: Deduplicate mapper interfaces at source

## Why
Mapper discovery can emit duplicate interface updates when the same device is scanned via multiple seeds or when both SNMP and API discovery are enabled. This inflates interface counts and causes redundant payloads downstream. We want the mapper engine to publish a single, merged interface record per unique interface.

## What Changes
- Define a canonical interface key (device identity + interface identifier) inside the mapper engine.
- Merge interface attributes discovered from multiple sources (SNMP/API) into a single interface record before publishing.
- Ensure mapper job results and published payloads contain unique interfaces only.
- Add regression coverage for interface de-duplication and merge behavior.

## Impact
- Affected specs: `openspec/specs/network-discovery/spec.md`
- Affected code: `pkg/mapper/discovery.go`, `pkg/mapper/snmp_polling.go`, `pkg/mapper/types.go` (and related tests)
