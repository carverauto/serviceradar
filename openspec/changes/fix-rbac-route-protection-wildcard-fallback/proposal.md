# Change: Fix RBAC route protection wildcard fallback for method-specific exact matches

## Why
GitHub issue #2147 (https://github.com/carverauto/serviceradar/issues/2147) reports a security bug in `pkg/core/auth/rbac.go:getRequiredRoles`: when an exact-path `route_protection` entry exists but does not define roles for the requested HTTP method, the code returns an empty role list and bypasses wildcard protections (for example `/api/admin/*`). This can unintentionally grant access to protected routes for authenticated users without the expected roles.

## What Changes
- Update RBAC route role resolution so exact path matches only take precedence when they yield required roles for the requested HTTP method; otherwise wildcard protections are still evaluated.
- Add regression tests covering exact-match + method-map + wildcard combinations to prevent future bypasses.
- Document the intended precedence rules for `route_protection` entries (exact vs wildcard; method-specific vs array).

## Impact
- Affected specs: `rbac-route-protection` (new)
- Affected code: `pkg/core/auth/rbac.go`, `pkg/core/auth/*_test.go` (new/updated)
- Compatibility: This is a security-hardening bug fix. Configurations that unintentionally relied on the bypass (exact match missing method allowing access) will become more restrictive.
- Out of scope: Changing the `route_protection` schema, changing the meaning of “empty required roles” beyond the wildcard fallback behavior, or introducing deterministic precedence between multiple overlapping wildcard patterns.

## Success Criteria
- A request to a route matched by a wildcard protection does not become unprotected just because an exact path entry exists for the same route without roles for that method.
- Unit tests reproduce the bypass case from issue #2147 and pass with the fix.
