# Change: Harden NATS Account Scope Guardrails

## Why
The NATS account-signing helpers currently accept arbitrary imports, exports, subject mappings, and user permission overrides, and new accounts receive unlimited JetStream quotas by default. An authorized caller can therefore mint credentials or account JWTs that escape namespace/account boundaries or exhaust JetStream resources.

## What Changes
- reject caller-supplied NATS imports, exports, mappings, and user permission overrides that escape the approved namespace/account scope
- keep least-privilege defaults in the signing layer instead of trusting arbitrary subject patterns from callers
- replace unlimited default JetStream quotas with explicit bounded defaults or required finite limits
- add focused tests for rejected cross-namespace authority widening and bounded JetStream claims

## Impact
- Affected specs:
  - `nats-tenant-isolation`
  - `tenant-workload-provisioning`
- Affected code:
  - `go/pkg/nats/accounts/account_manager.go`
  - `go/pkg/nats/accounts/user_manager.go`
  - `go/pkg/datasvc/nats_account_service.go`
  - `go/pkg/nats/accounts/*_test.go`
  - `go/pkg/datasvc/nats_account_service_test.go`
