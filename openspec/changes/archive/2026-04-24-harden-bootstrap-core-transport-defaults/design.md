## Context
`go/pkg/config/bootstrap` is used by bootstrap/config tooling that publishes default configuration templates to the core gRPC service. The package currently constructs its own transport behavior instead of inheriting the fail-closed contract from the hardened shared gRPC package.

If `CORE_SEC_MODE` is unset or set to `none`, `BuildCoreDialOptionsFromEnv` returns `insecure.NewCredentials()`. That means a caller can still reach core over plaintext just by omitting security configuration in the bootstrap environment.

## Goals
- Make bootstrap-to-core gRPC transport fail closed by default.
- Keep bootstrap transport behavior aligned with the hardened shared gRPC package.
- Preserve explicit secure modes (`spiffe`, `mtls`) without changing their semantics.

## Non-Goals
- Redesigning bootstrap template registration.
- Adding a new insecure/dev mode for this package.
- Changing the core registration RPC itself.

## Decisions
### Reject empty and insecure bootstrap security modes
Bootstrap template registration crosses a control-plane trust boundary and should not silently downgrade. The package will reject `CORE_SEC_MODE=""` and `CORE_SEC_MODE=none` instead of returning plaintext transport credentials.

### Keep secure mode parsing local but fail-closed
The package will continue to read `CORE_*` environment variables locally, but it must not reintroduce transport behavior that the shared gRPC package now rejects. The local helper should only produce secure client credentials.

## Verification
- Unit tests cover empty, `none`, `mtls`, and `spiffe` mode handling.
- Existing bootstrap callers compile without relying on plaintext fallback.
