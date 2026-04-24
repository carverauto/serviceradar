## Context
- Collector and edge onboarding flows generate operator-facing shell scripts and copy-paste install commands.
- Some of those generators still interpolate user-controlled values into double-quoted shell assignments after only stripping double quotes, which does not block command substitution.
- Sensitive endpoints such as topology snapshots and spatial samples rely too heavily on router placement rather than explicit controller authorization checks.
- SSO provisioning still auto-links existing local users by email, which is unsafe when local and federated identity ownership are not explicitly proven.
- Password reset requests can currently be spammed without throttling.
- Some bundle endpoints still return `inspect(reason)` in 500 responses.
- The SAML controller still contains the older ineffective XML parser options in the ACS path.

## Goals
- Ensure generated shell scripts treat embedded values as literal data.
- Fail closed on controller authorization for sensitive data endpoints.
- Prevent silent account takeover via email-based SSO auto-linking.
- Limit password reset abuse.
- Avoid leaking internal error terms to clients.
- Eliminate unsafe XML external resource handling in the SAML ACS path.

## Non-Goals
- Changing the overall onboarding UX beyond safer generated commands/scripts.
- Implementing a full user-facing account-linking UI in this change.
- Broad SSRF policy work outside the specific validated issues above.

## Decisions
- Replace the current shell sanitization helper with a single-quote-safe escaping helper and use single-quoted shell assignments where operator data is embedded.
- Add explicit permission checks to topology snapshot and spatial sample controllers so the authorization contract is enforced even if router placement changes later.
- For existing local users found by SSO email, refuse implicit linking unless the account is already explicitly eligible under the new policy; default behavior is fail closed instead of silently attaching the external identity.
- Apply the existing auth rate limiter to `request_reset/2`.
- Replace raw `inspect(reason)` bundle error responses with stable client-safe error messages and server-side logging.
- Reuse the same XXE-safe XML parsing approach in `SAMLController` that is now required for other SAML parsing paths.

## Risks / Trade-offs
- Some operators may currently rely on implicit email-based SSO linking; those flows will become stricter and may require admin intervention for legacy accounts.
- Tightening controller authz may reveal tests or scripts that depended on route-only protection.
- Safer bundle error messages reduce debugging detail in client responses, so server-side logging needs to stay adequate.

## Migration Plan
1. Harden shell script generators and controller-side generated scripts.
2. Add explicit RBAC/authorization checks to sensitive controllers.
3. Change SSO linking behavior to fail closed on ambiguous email matches.
4. Add password reset throttling.
5. Redact bundle 500 responses.
6. Harden the SAML ACS parser and add focused regressions.
