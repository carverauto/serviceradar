# Tasks: Fix RBAC route protection wildcard fallback for method-specific exact matches

## 1. Define expected behavior
- [x] 1.1 Capture precedence rules for `route_protection` (exact match vs wildcard; array vs method map).
- [x] 1.2 Identify affected configs (core.json, Helm config) and confirm they are compatible with the corrected behavior.

## 2. Implement the fix
- [x] 2.1 Update `getRequiredRoles` to fall back to wildcard matches when an exact match yields no roles for the requested method.
- [x] 2.2 Ensure the fix preserves method-specific overrides when roles are defined for the method.

## 3. Tests and validation
- [x] 3.1 Add unit tests reproducing the bypass scenario from GitHub issue #2147.
- [x] 3.2 Add unit tests proving method-specific exact matches still override wildcard roles for the same path/method.
- [x] 3.3 Run `gofmt` and targeted `go test ./pkg/core/auth`.
- [x] 3.4 Run `openspec validate fix-rbac-route-protection-wildcard-fallback --strict`.
