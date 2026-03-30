## Context
The admin API has two adapters:
- `AdminApi.Http` issues authenticated internal HTTP requests to the admin endpoints
- `AdminApi.Local` performs the same operations directly against Ash resources for tests/local use

The current implementation leaves four correctness/security gaps:
- HTTP path segments interpolate raw IDs
- local user updates can partially commit before later steps fail
- `role_profile_id: nil` is treated the same as "not provided"
- user list limits are not bounded and malformed integer types can crash parsing

## Goals / Non-Goals
- Goals:
  - prevent path traversal/SSRF through raw admin API path interpolation
  - ensure user update operations are atomic
  - allow explicit role-profile removal
  - bound pagination work and avoid trivial parser crashes
- Non-Goals:
  - redesign the admin API surface
  - redesign RBAC or role-profile semantics

## Decisions
- Decision: encode every path segment with `URI.encode_www_form/1`.
  - Rationale: path parameters should never be merged raw into URL paths.
- Decision: combine local user updates into a single update operation within one transaction boundary.
  - Rationale: role/display/profile changes affect privilege state and must not partially commit.
- Decision: treat missing `role_profile_id` as `:not_provided` and explicit nil/empty as a clear request.
  - Rationale: admins need a reliable way to revoke an assigned profile.
- Decision: clamp `limit` to a fixed maximum and accept integer values directly.
  - Rationale: prevents accidental or malicious oversized reads and parser crashes.

## Risks / Trade-offs
- Tightening atomic updates may require touching existing Ash actions rather than layering more controller logic.
  - Mitigation: prefer the Ash-native path if available; otherwise use a clear transaction boundary.
- Encoding path segments may change behavior for callers that previously relied on raw slashes in IDs.
  - Mitigation: IDs should be opaque identifiers, not path fragments.

## Migration Plan
1. Encode path parameters in the HTTP admin API adapter.
2. Refactor local user update into one atomic update path.
3. Introduce explicit `:not_provided` handling for optional update attrs.
4. Clamp and normalize list-user limits and update focused tests.

## Open Questions
- None.
