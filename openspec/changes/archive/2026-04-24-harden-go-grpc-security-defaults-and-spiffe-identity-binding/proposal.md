# Change: Harden Go gRPC Security Defaults And SPIFFE Identity Binding

## Why
The repository security review found two shared trust-boundary problems in `go/pkg/grpc`: the package still fails open to insecure transport when callers omit security configuration, and the SPIFFE provider still broadens peer authorization to any-SPIFFE or trust-domain-wide membership when exact server identity is omitted.

## What Changes
- Remove implicit insecure transport fallback from the shared gRPC client/provider constructors and require explicit opt-in for `none` mode in narrowly-scoped call sites.
- Require SPIFFE client and server credentials to fail closed unless the expected peer identity constraints are configured.
- Add focused tests that reject nil/empty security defaults and overly-broad SPIFFE authorization configuration.

## Impact
- Affected specs: `edge-architecture`
- Affected code:
  - `go/pkg/grpc/client.go`
  - `go/pkg/grpc/security.go`
  - `go/pkg/grpc/security_test.go`
