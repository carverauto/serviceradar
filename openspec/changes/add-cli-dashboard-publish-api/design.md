## Context

ServiceRadar's web-ng exposes browser-side "dashboard packages" — manifest + JS/Wasm renderer — that operators install to surface custom views (the customer network map is the reference customer use of this surface). Today the only ingress for a freshly authored package is a Settings → Dashboard Packages LiveView upload modal that requires a session-authenticated admin. The serviceradar-cli ships a `dashboard publish` subcommand that already targets `POST /api/v1/dashboard-packages` + `POST /api/v1/dashboard-packages/:id/enable`, but those routes don't exist; the CLI errors out with a 404 against the Phoenix router. The cli-device-auth proposal lands the JWT minting half (with a `dashboard.publish` scope claim); this proposal lands the API half so the two compose.

Stakeholders: dashboard authors (carverauto + customer SDK consumers), admins (revoke/audit), platform team (bytes served from this surface execute in operator browsers — same blast radius as a customer-installed Chrome extension).

Constraints:
- Must reuse existing primitives (`Packages.import_json/3`, `Manifest.from_json`, `Storage.put_blob`, `DashboardPackage` Ash policies). No parallel ingestion path.
- Must be safe under a JWT minted by the CLI device-code flow (long-lived 30 d default), not just under a session-cookie admin.
- Must not regress the existing LiveView upload UX: the LiveView path SHALL pick up every server-side check this proposal adds, not bypass them.
- Must work on the existing `:api_key_auth` Phoenix pipeline so the cli-device-auth JWT validates exactly the same way it does for `/v1/field-survey/auth-check`.

## Goals / Non-Goals

**Goals**
- A CLI-driven publish round-trip that completes in a single `serviceradar-cli dashboard publish --instance … --route … --enable --yes` call, with no LiveView interaction.
- Defense in depth: bearer-token scope check + RBAC permission check + Ash resource policy. A vulnerability in any one layer SHALL NOT yield publish capability.
- Safe re-publish: `manifest.id@version` is upserted by content; a re-push with the same bytes is a noop, and a re-push with different bytes is rejected unless the package is currently `:disabled` or the version was bumped.
- Safe slug ownership: a slug already bound to package A SHALL NOT be silently rebound to package B by a different author. Conflict surfaces as a structured 409 with the colliding `dashboard_id`.
- Bounded resource consumption: explicit byte caps on every part of the multipart, rate-limited by token, audit-logged on each successful and failed write.
- Symmetric disable so the CLI has a clean rollback path without a LiveView trip.

**Non-Goals**
- No new content-signing scheme. The renderer SHA256 already in `manifest.renderer.sha256` is the integrity primitive; the existing `signed-wasm-plugin-import` capability covers signed uploads and is orthogonal.
- No new content-delivery surface. The asset controller (`/api/v1/dashboard-packages/:id/renderer{,.wasm}`) and CSP enforcement around it are out of scope here. (The CSP question is non-trivial — see Open Questions.)
- No GitHub-trigger or webhook publish flow. `Packages.import_github/2` already exists for that path; this proposal only ships the direct multipart upload.
- No multi-tenant scoping by `tenant_id` beyond what `DashboardPackage` already inherits from the connection's search_path. Cross-tenant ownership is out of scope; this surface is single-tenant in the existing deployment model.
- No `PATCH /api/v1/dashboard-packages/:id` for partial updates. Authors bump `manifest.version` instead — this preserves the immutability of any served renderer SHA256.
- No `DELETE /api/v1/dashboard-packages/:id`. Disable is the destructive primitive at the API layer; hard-delete remains an admin-only LiveView action.

## Decisions

### Decision 1: Defense-in-depth gating, three layers

Every publish/enable/disable request SHALL pass:

1. **Phoenix pipeline** (`:api_key_auth`) — `Plugs.ApiAuth` validates the bearer JWT, sets `current_scope`, `oauth_token_scope`, and Ash actor.
2. **Route plug** (`Plugs.RequireOauthScope`) — verifies the JWT's `scopes` claim contains `dashboard.publish`. Rejects with 403 + `{"error":"insufficient_scope","required":"dashboard.publish"}` if missing. This catches the case where a user has the RBAC permission but their CLI session JWT was minted for a narrower scope.
3. **Controller** — checks the user's RBAC permission (`cli.dashboard.publish` for `POST /…`, `cli.dashboard.enable` for `…/enable`, `cli.dashboard.disable` for `…/disable`) via `RBAC.can?(scope, "cli.dashboard.publish")`. Rejects with 403 + `{"error":"forbidden","permission":"cli.dashboard.publish"}` if missing. This catches the case where an admin's session was hijacked to mint a JWT but the role was downgraded since — RBAC is the live source of truth.

The Ash resource policies on `DashboardPackage` continue to bypass for system actors and gate non-system actors on `plugins.stage`/`plugins.approve` for the existing LiveView path. The new API path runs as the user actor, but the controller wraps `Packages.import_json/3` with `actor: ash_actor` so the Ash policy still applies. This way an attacker who bypasses the controller-level RBAC check (e.g. via a future refactor that drops the call) still hits the Ash policy.

**Alternatives considered:**
- *Single RBAC permission `cli.dashboard.publish` with `enable` and `disable` implied.* Rejected because we want to be able to grant a role the ability to push new versions for review without granting it the ability to flip them live. The three-permission split mirrors the `plugins.{stage,approve}` distinction the LiveView already uses, just with API-shaped names.
- *Reuse `plugins.stage` / `plugins.approve` directly.* Rejected because those permissions cover plugin packages (which are agent-executed Wasm with a wider blast radius) plus dashboard packages today — granting `plugins.stage` for the CLI publish path would over-grant the agent-side plugin surface. Keeping CLI dashboard publish as its own permission cluster keeps the principle of least privilege intact.
- *Token-scope check only, no RBAC.* Rejected because token scopes are minted at login and don't shrink when the user's role does. RBAC is the live revocation layer.

### Decision 2: Route-slug ownership

A slug-binding `DashboardInstance` row SHALL belong to exactly one `dashboard_id` while it's `enabled = true`. The publish controller, before calling `Packages.import_json/3`, SHALL resolve the requested `route` against `DashboardInstance` and:

- **No row exists** → proceed; we'll create the binding after the package upserts.
- **Row exists, dashboard_id == manifest.id, enabled = true** → proceed; this is a re-publish to the same slug. Update the binding to point at the new package version.
- **Row exists, dashboard_id == manifest.id, enabled = false** → proceed; we'll re-enable the binding (only on the explicit `…/enable` call, not the publish itself).
- **Row exists, dashboard_id != manifest.id, enabled = true** → reject with 409 `{"error":"slug_in_use","route":<slug>,"owner_dashboard_id":<id>}`. The CLI surfaces this as a hint to pick a different `--route`.
- **Row exists, dashboard_id != manifest.id, enabled = false** → proceed; an enabled binding takes precedence, but a disabled binding for a different package can be replaced. The previous binding's row remains; we create a new binding row for the new package and leave the old one disabled. (Hard-delete is an admin LiveView action.)

The check SHALL run inside the same transaction as the `import_json/3` upsert + binding so a concurrent publish to the same slug serializes through PostgreSQL. The controller SHALL retry once on the `Postgrex.Error` `:serialization_failure` retcode (advisory lock optional; the unique route_slug index is the authoritative serialization point).

**Alternatives considered:**
- *Allow any author to overwrite any disabled binding.* Rejected — too lenient. A disabled binding is still authoritative ownership history; we let the new author take it only if no enabled row blocks them.
- *First-publish-wins forever.* Rejected — too rigid. An admin needs a way to re-bind a slug when a package is decommissioned. Disable then publish is the documented flow.

### Decision 3: Version-overwrite rule

`DashboardPackage.upsert` is keyed on `unique_dashboard_version` ([:dashboard_id, :version]). Re-pushing the same `id@version` is allowed by Ash, but we want stronger guarantees so we don't silently swap renderer bytes under operators' browsers:

- If the upsert resolves to an existing row whose `content_hash` matches the new bytes' SHA256: noop (truly idempotent — return 200 with the existing package row).
- If the existing row's `content_hash` differs and the existing row is `:enabled` or `:verification_status: "verified"`: reject with 409 `{"error":"version_already_published","dashboard_id","version","existing_content_hash"}`. The CLI surfaces this as a hint to bump `manifest.version` or run disable first.
- If the existing row is `:disabled` (or revoked): allow the overwrite, but reset `verification_status` to `"pending"` so a subsequent enable re-runs verification.

This rule is enforced in `Packages.import_json/3` (or a sibling `Packages.publish/3` that wraps it) so the LiveView upload path picks it up too.

**Alternatives considered:**
- *Strictly forbid same-version re-push.* Rejected — breaks idempotent retries from the CLI when the response is lost mid-flight (TCP reset, etc.). The "same bytes → noop" path is exactly what an idempotent client needs.
- *Silently overwrite.* Rejected — anyone with publish capability could swap the renderer code under a known stable version label. Operator browsers cache by ETag (`content_hash`) so the swap could go undetected for hours.

### Decision 4: Multipart vs. JSON request body

The CLI sends `multipart/form-data` with three parts: `manifest` (JSON blob), `renderer` (binary blob), `route` (text field). The controller decodes via Plug.Parsers `:multipart` (already mounted by the `:api_key_auth` pipeline's `:accepts ["json"]` plus a per-route `:multipart` accept).

**Why not pure JSON?** The renderer is regularly 700 KB+ minified JS (the customer dashboard is 710 KB) and 5 MB+ for sample-frames. Base64-encoding into a JSON body inflates 33% and forces both ends to allocate the full payload as a string — a multipart body is streamed. The CLI is already multipart today.

**Why not pre-signed URL upload?** The `Storage` module supports pre-signed URLs (`upload_url/1`, `verify_token/2`) but the LiveView upload doesn't use them — it inlines the bytes. Adding a pre-signed-URL flow for the CLI is a separate optimization; the current 50 MB cap is well under typical multipart limits.

**Multipart hardening:**
- `Plug.Parsers` config: `:multipart` with `length: 64 MB` (manifest 256 KB cap + renderer 50 MB cap + sample fields with headroom). Documented per-route via a route-scoped pipeline `:dashboard_publish_uploads`.
- Per-part length caps enforced post-parse in the controller before any disk/blob write: manifest > 256 KB → 413; renderer > 50 MB → 413.
- Content-type pinning per part: `manifest` part SHALL declare `application/json`; `renderer` part SHALL declare `application/javascript`, `text/javascript`, or `application/wasm`. Anything else → 415.

### Decision 5: Audit logging + CLI session use-tracking

Every successful publish/enable/disable hop SHALL:
1. Write an audit row via the existing audit sink with `{actor_user_id, jti, action: :dashboard_publish | :dashboard_enable | :dashboard_disable, dashboard_id, version, route_slug, content_hash, ip}`. The cli-device-auth `CliSession` carries the `jti`; we look it up from the JWT claims. Audit failures are best-effort and SHALL NOT fail the publish.
2. Call `CliSession.record_use(jti, actor: system_actor)` to bump `last_used_at` + `use_count` so the Settings → CLI sessions page reflects publish activity. (The existing ApiAuth plug already calls `record_use` on every JWT hop, so this is implicit — no new code path needed.)

### Decision 6: Rate limiting

10 publish attempts/minute per `jti` (CLI session token). Matches the cadence of the device-code endpoint and is generous for a build-publish loop (a fast author publishes once every 30–60 s; 10/min is 6× headroom). Implemented via the existing `ServiceRadarWebNG.RateLimit` GenServer (or `Hammer` if that's what the cli-device-auth proposal landed). 429 response carries `Retry-After: <seconds>` header.

Enable/disable endpoints share a separate 30/min/jti budget — they're cheap and authors hit them more often during dev.

## Risks / Trade-offs

- **Risk: long-lived JWTs amplify the blow if a single token leaks.** Mitigation: the cli-device-auth proposal already ships a Settings → CLI sessions revoke flow with `RevokedToken` denylist. Combined with audit-log entries on every publish, a leak is detectable and revocable. We are NOT shortening the JWT TTL further as part of this proposal — that's a separate operational tuning question.
- **Risk: a malicious author with `cli.dashboard.publish` could publish a renderer that exfiltrates the operator's session via fetch().** Mitigation: out of scope for this proposal — the renderer-CSP problem applies to the existing LiveView upload path equally and is tracked separately. Documented in Open Questions.
- **Risk: route-slug ownership rule could be raced** (two CLI publishes to the same fresh slug land between the existence-check and the binding-insert). Mitigation: the `DashboardInstance.route_slug` index serializes; the controller wraps the check + bind in a single transaction with `Repo.transaction(fn -> … end)`. Race resolves at the unique index — second writer gets a 409.
- **Risk: idempotent re-push with the same bytes returns 200 when an attacker would prefer the publish to be silently a no-op (covering tracks).** Mitigation: audit log fires regardless of noop status — every API hop is logged with `{result: :idempotent_noop | :written}`.
- **Trade-off: separate `cli.dashboard.{publish,enable,disable}` permissions instead of inheriting `plugins.{stage,approve}`.** Costs three RBAC catalog entries; benefits the principle-of-least-privilege story for orgs that want to grant CLI publish without granting plugin admin. The defaults map both new permissions to admin, so the catalog growth is invisible to existing deployments.
- **Trade-off: multipart vs pre-signed URL.** Multipart is simpler today (matches the existing LiveView path; CLI is already multipart) but caps the renderer at 50 MB. If a customer ships a 500 MB renderer we'll need a pre-signed-URL flow; not on the near horizon.

## Migration Plan

This is purely additive — three new routes, one new plug, one new controller, three new RBAC permissions, two extended functions in `Packages`. No existing code paths change behavior, no schema migrations.

**Rollout:**
1. Land the migration that adds the three RBAC permissions to the catalog (idempotent — `RBAC.ensure_catalog/1` upserts).
2. Land the controller + plug + route additions.
3. Bump `web-ng` to a pre-release tag, smoke against the local docker stack with `serviceradar-cli dashboard publish`.
4. Once green, ship to staging, validate the customer dashboard SDK loop end-to-end (CLI build → CLI publish → operator browser GET).
5. Tag a full release.

**Rollback:** revert the route block + controller + plug. The Ash resource is unchanged, the `Packages` context's new validation path is gated by a `route` parameter and is a noop when the parameter is absent (LiveView upload doesn't pass it). RBAC permissions persist harmlessly if the ingress is reverted.

## Open Questions

1. **Renderer CSP.** The asset controller serves uploaded JS bytes with `text/javascript` and immutable cache headers. The CSP for the `/dashboards/:slug` LiveView page needs to allow inline-import of that script while keeping it sandboxed from the operator's session storage. This is a pre-existing concern that the LiveView upload path already inherits — solving it here is out of scope, but we SHOULD link the problem to a separate proposal so the publish surface doesn't become the documented root cause once it's exploited.
2. **Public verification artifact.** The cli-device-auth `signed-wasm-plugin-import` capability adds Sigstore-style signature checks for the agent-side plugin path. Should the dashboard-package publish API also accept a detached signature part (`signature` form field, optional) and store it alongside `content_hash`? Recommendation: **no, not in this proposal** — keep it scoped — but design the multipart parser so a future `signature` part can be threaded through without a breaking change to the controller contract.
3. **`DashboardInstance.settings` defaults.** The CLI publishes with `route` only; instance settings (placement, is_default, settings JSON) are LiveView-only today. Recommendation: when the API creates a new instance row, default it to `placement: :main, is_default: false, enabled: false` (the explicit `…/enable` call sets `enabled: true`). The author flips `is_default` via the LiveView if they want it as the landing dashboard.
