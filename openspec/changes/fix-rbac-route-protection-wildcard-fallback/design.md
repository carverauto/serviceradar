## Context
`pkg/core/auth/rbac.go:getRequiredRoles` determines which RBAC roles are required for a given HTTP path + method using the `rbac.route_protection` config. The current implementation returns immediately on an exact path match, even when that exact match is a method-specific map that does not include the requested method. This causes wildcard protections (for example `/api/admin/*`) to be skipped.

## Goals / Non-Goals
- Goals:
  - Prevent method-specific exact matches from bypassing wildcard protections when the method is not explicitly protected by the exact match.
  - Preserve the ability for method-specific exact matches to override wildcard protections when the method is explicitly listed.
  - Add tests that fail if this bypass reappears.
- Non-Goals:
  - Redesign the RBAC configuration schema.
  - Change the middleware semantics where “no required roles” means “no role check”.
  - Define or implement deterministic precedence between multiple overlapping wildcard patterns (unless required by follow-up work).

## Decisions
- Decision: Treat an exact path protection as applicable only if it yields at least one role for the requested method.
  - Rationale: Method-specific maps are intended to scope protection to listed methods. Returning an empty role list should not disable more general protections that still apply.
  - Result: `getRequiredRoles` will compute roles from the exact match and return them only when non-empty; otherwise it will continue evaluating wildcard patterns.

## Risks / Trade-offs
- Risk: Some deployments may have relied (unknowingly) on the bypass for access patterns.
  - Mitigation: Treat this as a security bug fix; document the change and add tests demonstrating the intended behavior.

## Migration Plan
- No storage migration.
- Code-only change in `pkg/core/auth`; roll out as a patch release after validation.

## Open Questions
- Should wildcard precedence be deterministic when multiple patterns match (for example, prefer the most-specific prefix match)?
- Should method maps support an explicit “default/any method” key (for example `"*"`), and how should it interact with wildcards?
