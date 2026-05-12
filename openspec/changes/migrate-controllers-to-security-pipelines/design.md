## Context

`add-platform-security-hardening` (merged) shipped a cluster-aware
`ServiceRadar.Security.RateLimiter`, the `RateLimit` and
`LockoutCheck` plugs, eight named rate-limit pipelines in
`router.ex`, and a backwards-compat `Auth.RateLimiter` shim so the
existing controllers kept working. None of the pipelines are
attached to a route today. The auth controllers still call the
shim inline, and each manages its own per-route limits via
module attributes rather than the central
`ServiceRadar.Security.RateLimiter` bucket map.

The follow-up issue from that work — and the reason this proposal
exists — is that the rollout step was deferred. The architectural
piece that's missing in the plug is an HTML response mode: the
auth controllers redirect + flash on rate-limit, the plug returns
JSON 429. Until the plug speaks both, it can't replace the inline
calls on HTML routes.

## Goals / Non-Goals

**Goals**
- Move every credential-path rate-limit check from inline
  `Auth.RateLimiter.*` calls onto a pipeline-attached `RateLimit`
  plug. One central place to tune limits.
- Wire `LockoutCheck` onto auth pipelines so locked actors are
  short-circuited at the pipeline boundary uniformly.
- Surface OIDC / SAML failed-auth attempts into `SecurityEvent`
  + the lockout trigger.
- Delete the `Auth.RateLimiter` shim once no callers remain.

**Non-Goals**
- CLI device-auth migration. Its 429 JSON shape
  (`{code, error, message}`) is consumed by parsed CLI clients
  and differs from the plug's `{error, retry_after}`. Aligning
  shapes is a separate concern.
- Touching the `Settings → Audit` LiveViews; they already
  consume `SecurityEvent` and `AuthLockout` correctly.
- New buckets beyond the ones that mirror existing inline call
  sites. The proposal does not introduce new rate-limit
  policies, only relocates existing ones.

## Decisions

### D1. Accept-aware response mode in the plug

`Plug.Conn.get_req_header(conn, "accept")` reveals the client's
preferred content type. The plug's `call/2` inspects this and
branches:

- Accept includes `text/html` (or `*/*` with the connection
  coming through a `:browser`-shape pipeline): return a 303 See
  Other redirect to `:html_redirect_to` opt with a `Phoenix.Flash`
  error.
- Otherwise: existing JSON 429.

Plug opts:

- `:html_redirect_to` — atom verified-route or string path.
  Default: `"/users/log-in"` for `:auth_local` bucket, route
  prefix for others.
- `:html_flash_template` — string with `#{retry_after}`
  interpolation. Defaults to "Too many attempts; try again in
  #{retry_after} seconds."
- `:response_mode` — `:auto` (default, sniff Accept), `:json`,
  `:html`. Pipelines that are JSON-only force `:json` so a
  malformed Accept header doesn't accidentally redirect.

The plug records the same `SecurityEvent` regardless of response
mode — operator visibility shouldn't depend on the client's
content negotiation.

### D2. LockoutCheck Accept-awareness

Same shape as D1: HTML redirects to a configurable sign-in path
with a "Account temporarily locked. Try again later." flash;
JSON returns HTTP 423 with `{error: "account_locked"}`. The
existing `:actor_id_param` / `:actor_id_assign` opts are
preserved.

### D3. Pipeline ↔ controller alignment

| Route group | Pipeline | Lockout? |
|---|---|---|
| `POST /auth/sign-in`, `POST /auth/local` | `:rate_limit_auth_local` | yes — actor_id from `user[email]` param |
| `POST /auth/password-reset`, `PUT /auth/password-reset/:token` | `:rate_limit_password_reset` (new) | no — already rate-limited; lockout adds little |
| `GET /auth/oidc/callback` | `:rate_limit_auth_oidc` | no — callback has no controllable actor id pre-validation |
| `GET /auth/saml/callback` | `:rate_limit_auth_saml` | no — same |
| `POST /oauth/token { grant_type=password }` | `:rate_limit_oauth_password` (new) | yes — actor_id from `username` body field |
| `POST /oauth/token { grant_type=client_credentials }` | `:rate_limit_oauth_client_credentials` (new) | no — service-to-service, not a brute-force vector |
| `POST /api/v1/cli/auth/device`, `POST /api/v1/cli/auth/token` | **unchanged** | n/a (out of scope per non-goals) |

OIDC and SAML callback controllers gain a
`Lockouts.record_failed_login(actor_id, …)` call when the asserted
claims include an email but ID-token verification or user lookup
fails. Cross-IP repeated SSO failures for the same federated
identity then trip the existing lockout threshold.

### D4. Bucket / pipeline naming

The new atom buckets match the existing string action names
verbatim where possible so the rename is mechanical:

- `"password_auth"` → `:auth_local`
- `"local_auth"` → `:auth_local` (same bucket — both are HTML
  password sign-in)
- `"password_reset"` → `:auth_password_reset`
- `"oidc_callback"` → `:auth_oidc_callback`
- `"saml_consume"` → `:auth_saml_callback`
- `"oauth_password_grant"` → `:oauth_password_grant`
- `"oauth_client_credentials"` → `:oauth_client_credentials`

In-flight rate-limit state for the string buckets does not roll
forward to the atom buckets. Any actor at-limit gets a fresh
window at deploy. No user-visible regression — they were already
locked out moments earlier.

### D5. Removal of the shim

Once the migration is complete and `Auth.RateLimiter` has no
callers, delete `lib/serviceradar_web_ng_web/auth/rate_limiter.ex`.
`grep -r "Auth.RateLimiter" elixir/web-ng/lib elixir/web-ng/test`
must return zero hits before the deletion commit.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Pipeline-level rate-limit pre-empts controller logic that wants to gracefully redirect logged-in users mid-flow | Pipeline plug runs after `:fetch_session`; we can check `current_user` and bypass. For v1 the rate-limit is route-specific so this isn't a concern, but flagging. |
| Accept-sniffing misclassifies a JSON client | `:response_mode` opt forces JSON for API-only pipelines. Default `:auto` is safe for HTML browser routes. |
| LockoutCheck on a pipeline blocks the sign-in page render | LockoutCheck only halts on POST (the credential submit). GETs (form render) pass through because `actor_id_param` extraction returns nil. |
| Bucket rename invalidates in-flight rate-limits | Acceptable — a hostile client wasted its existing budget; legitimate users had at most one failed attempt and won't notice. |
| OIDC/SAML record_failed_login could over-trigger on transient claim parsing failures | Only call when failure mode indicates wrong identity (signature mismatch, audience mismatch, missing required claim), not transient errors (network, IDP unreachable). Document the predicate. |

## Migration Plan

1. Land D1 + D2 (Accept-aware plug response). No behavior change
   to existing routes since no route uses the pipelines yet.
2. Add new buckets to config + new pipelines to router.
3. Migrate `auth_controller` routes (HTML, highest risk): wire
   pipeline, remove inline calls, smoke-test sign-in.
4. Migrate `oauth_controller` (JSON): same pattern, easier.
5. Migrate `oidc_controller` and `saml_controller`: rate-limit
   pipeline + add `record_failed_login` calls.
6. Delete the shim. Final commit.

Each step is independently revertible: revert the controller
change first, then the router change. The plug itself remains
useful from the first commit.

## Open Questions

1. Should `:rate_limit_auth_local` redirect target be configurable
   per route (so `/auth/sign-in` redirects to `/users/log-in` and
   `/auth/local` redirects to `/auth/local`)? Leaning yes via
   plug opts at the route scope.
2. Should we add a `:rate_limit_audit_view` bucket for the
   audit-page reads to protect SecurityEvent enumeration? Out
   of scope; tracked separately if it becomes a concern.
