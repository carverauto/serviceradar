# Change: Fix mapper interface count reporting

## Why
Mapper interface results are currently logged and summarized with an inflated interface count (issue #2417), which obscures the true discovery footprint and makes triage harder.

## What Changes
- Normalize mapper interface updates to a canonical key and de-duplicate before counting or logging.
- Ensure mapper interface count reporting matches the unique interfaces delivered in the payload.
- Add regression coverage for duplicate interface updates.

## Impact
- Affected specs: `openspec/specs/network-discovery/spec.md`
- Affected code: `pkg/agent/mapper_service.go`, `pkg/agent/push_loop.go` (mapper results handling and logging)
