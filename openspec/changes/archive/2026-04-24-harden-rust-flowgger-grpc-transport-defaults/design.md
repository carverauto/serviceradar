## Context
`rust/flowgger` can optionally spawn a gRPC health sidecar when `grpc.listen_addr` is configured. Today, that helper permits an explicit `grpc.mode = "none"` mode and, worse, treats `grpc.mode = "mtls"` without full certificate material as `SecuritySettings::None`.

That means operator intent to run authenticated gRPC can silently degrade into plaintext serving, which is inconsistent with the fail-closed transport contract now enforced across the rest of the repository.

## Goals
- Make flowgger gRPC fail closed by default.
- Require authenticated transport whenever the gRPC sidecar is enabled.
- Preserve the existing secure modes (`mtls`, `spiffe`) without changing their core behavior.

## Non-Goals
- Redesigning flowgger input/output behavior.
- Changing flowgger’s health service surface.
- Adding a new insecure development mode.

## Decisions
### Reject explicit insecure mode
`grpc.mode = "none"` will no longer be accepted for flowgger gRPC. If the sidecar is enabled, it must use mTLS or SPIFFE-backed serving.

### Treat incomplete mTLS as invalid configuration
If `grpc.mode = "mtls"` is selected, all required certificate paths must be present. Missing certificate material will become a configuration error rather than a downgrade to plaintext.

## Verification
- Unit tests cover explicit `none` rejection and incomplete mTLS rejection.
- Secure mode resolution still succeeds for valid mTLS and SPIFFE configurations.
- OpenSpec validation passes for the new change and updated baseline artifact.
