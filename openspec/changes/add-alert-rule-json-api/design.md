## Context

This grew out of `add-proxmox-host-outage-alerting` (same session): while
scoping alerting for two Proxmox VMs that silently stopped, we found that
provisioning an alert rule by API isn't possible today — `StatefulAlertRule`
lives in `ServiceRadar.Observability`, which isn't mounted on
`ServiceRadarWebNGWeb.AshJsonApiRouter`. A background research workflow (this
session) traced the actual mechanics end-to-end before this proposal was
written; the findings below are load-bearing for the design, not background
color.

### The macro problem

`stateful_alert_rule.ex` doesn't call `use Ash.Resource` itself — it invokes
`use ServiceRadar.Observability.PresetRuleResource, table: "stateful_alert_rules", ...`,
and `PresetRuleResource.__using__/1` is what actually expands to
`use Ash.Resource, domain: ..., data_layer: ..., authorizers: [...]` with
**no `extensions:` key**. `AshJsonApi.Resource` — the extension that makes
`json_api do ... end` a valid DSL section at all — is only ever declared
inline in a resource's single `use Ash.Resource` call (verified: 26 files in
this codebase declare it this way, zero declare it any other way, and
`use Ash.Resource` cannot be called twice on one module). So a bare
`json_api do end` typed into `stateful_alert_rule.ex` would not compile.

The same macro (`PresetRuleResource`) is also used by
`StatefulAlertRuleTemplate`, `LogPromotionRule`, and
`LogPromotionRuleTemplate` — none of which should get JSON:API routes from
this change. (`ZenRule`/`ZenRuleTemplate` use a different, sibling macro,
`ZenPresetResource`; `EventRule` uses no macro at all — both are unaffected
by anything done to `PresetRuleResource` regardless.)

The codebase already has the right pattern for this exact problem:
`ZenPresetResource.__using__/1` threads `extra_actions`, `extra_code_interface`,
and `extra_operator_actions` options through, each defaulting to `[]`/`nil`
via a small `eval_option/3` helper, and splices them into the shared
`actions do end`/`code_interface do end` blocks only when a caller passes
them (`zen_preset_resource.ex:16-18`, confirmed by direct read — see the
`active_action_ast`/`active_code_interface_ast` pattern there, which is
exactly this technique already in use for a different optional feature,
`active_sort`). `PresetRuleResource` doesn't have these options yet; this
change adds them, following the identical shape, plus a new `extensions:`
option (not present in either macro today, but the same technique applies).

### The blast-radius problem

`ServiceRadar.Observability` is not a blank slate waiting for its first
JSON:API resource. Reading `observability.ex`'s `resources do end` block
(60 resources) and grepping every file under `observability/` for `json_api`
turned up **19 resources that already have complete, dormant
`json_api do routes do index :read end end` blocks**: `Log`,
`ServiceStatus`, `CapacityForecast`, `CpuClusterMetric`, four OTel resources
(`OtelMetric`, `OtelMetricPoint`, `OtelTrace`, `OtelTraceSummary`), five
resources built from the shared `RawMetricResource` macro, and six from
`HourlyMetricResource`. All read-only, all already reviewed and merged by
whoever wrote them, all simply unreachable because the domain was never
mounted.

Ash's JSON:API router mounts **per domain**: `formatted_routes/1` iterates
every resource in each mounted domain and asks whether it has a `json_api`
DSL entity, defaulting to none. There is no per-resource allowlist at the
router level (confirmed against the installed `ash_json_api` dependency
source, and empirically against the codebase's own `Inventory` domain, which
is already mounted and has ~50 resources but only 6 with `json_api` blocks —
the other ~44 stay silent, proving the mechanism is opt-in per resource
*within* a mounted domain, but binary *across* domains: mount it and every
resource that already opted in goes live at once). So reaching
`StatefulAlertRule` via this router necessarily reaches all 19 others too.

Per the user, this is a feature, not a risk to route around: these 19
already exist, were already built and (presumably) reviewed for JSON:API
exposure, and simply never got a live domain mount. This change is what
finally reaches them. The only remaining obligation is to actually check
each one's read policy before flipping the mount — see tasks.md — not to
find a way to keep them dormant.

### The two sync points nobody keeps in sync

1. `OpenApiV2Controller` (serves the live, authenticated `/api/v2/open_api`
   document behind SwaggerUI/Redoc) hardcodes its own `@domains` list rather
   than reading `AshJsonApiRouter.domains()`. It's already stale today —
   missing `Notifications`, which the router does mount — with nothing
   catching the drift. This change must update it to include
   `Observability`; the pre-existing `Notifications` gap is a separate,
   already-present bug and gets its own follow-up (file it, don't silently
   fix it as a drive-by in this diff).
2. The committed `priv/static/openapi.json` (source of truth for
   `mix serviceradar.openapi.dump --check`) is only checked by a **nightly
   cron job against staging** (`buildbuddy.yaml`'s `"Elixir Quality (daily)"`,
   `schedule: crons: ["0 7 * * *"]`) — there is no `pull_request` or `push`
   trigger for it. A PR that adds routes and forgets to regenerate this file
   merges clean and silently drifts for up to a day. This change must run and
   commit the regeneration itself; do not rely on CI to catch a forgotten
   regen.

### The scope-enforcement gap (flagged, not fixed here)

Tracing the actor-construction path for a bearer token hitting `/api/v2/*`
(`UserAuth.fetch_current_scope_for_user` → `set_ash_actor`, **not**
`Plugs.ApiAuth`, which fronts a different set of pipelines) confirmed: the
`:ash_json_api` pipeline never wires in `RequireOauthScope` and never even
sets the `oauth_token_scope` assign that plug reads. Every policy decision
on `/api/v2/*` is `actor.role`-based only (`operator`/`admin`/`system` via
`is_operator/0`/`operator_action/1` in `policies.ex`). Concretely: a
`read`-scoped OAuth2 client-credentials token, minted for an admin user,
already has full create/update/destroy access to every mounted resource
today — this is not new. Exposing `StatefulAlertRule` moves this
pre-existing gap onto a resource where the consequence (an attacker or
buggy read-only integration silently disabling an alert rule) is more
severe than on, say, a service check. Fixing scope enforcement pipeline-wide
is a bigger, separate, higher-blast-radius change (it touches every mounted
domain, not just this one) and is out of scope here — flagged via a GitHub
issue instead.

## Goals / Non-Goals

**Goals**
- Let an operator (or automation, with an appropriately-scoped/role'd
  credential) create/read/update/destroy `StatefulAlertRule` rows over HTTP,
  matching what the existing rules UI already does internally.
- Do it via the smallest, most surgical change to the shared
  `PresetRuleResource` macro, with a regression test proving the three
  sibling resources are unaffected.
- Bring the 19 already-built, dormant Observability JSON:API resources
  online as a deliberate, reviewed part of this change.
- Keep both OpenAPI surfaces (`OpenApiV2Controller`'s live doc and the
  committed `priv/static/openapi.json`) in sync with the new mount, in this
  same change, since neither is safely enforced by existing tooling.

**Non-Goals**
- Fixing OAuth2 scope enforcement on the `:ash_json_api` pipeline. Real,
  pre-existing, worth fixing — but a platform-wide change independent of
  this one. File it, don't bundle it.
- Fixing `OpenApiV2Controller`'s pre-existing missing-`Notifications` bug.
  Same reasoning — file it separately.
- Exposing `StatefulAlertRuleState` or `StatefulAlertRuleHistory`. Neither
  shares the `PresetRuleResource` macro (both use plain `use Ash.Resource`),
  neither has a `json_api` block today, and neither has any current UI
  consumer beyond internal engine code
  (`stateful_alert_engine.ex`/`alert_lifecycle.ex`). No forcing function to
  expose them now; the 19-resource read-only pattern is a ready template if
  that changes later.
- Rehoming `StatefulAlertRule` into a different, more narrowly-mounted
  domain to dodge the blast-radius question. Not worth the churn to every
  internal reference to `ServiceRadar.Observability.StatefulAlertRule`, and
  the user has said the other 19 resources going live is welcome anyway.

## Decisions

- **Macro opt-in over de-macroing.** Threading `extensions:`/
  `extra_actions:`/`extra_code_interface:` through `PresetRuleResource`
  (mirroring `ZenPresetResource`'s existing, proven technique) keeps the four
  shared callers deduplicated. The alternative — forking
  `stateful_alert_rule.ex` off the macro and hand-writing its ~50 lines of
  `postgres`/`code_interface`/`actions`/`policies` DSL — was rejected: it
  risks drift the next time `PresetRuleResource`'s shared semantics change,
  for no benefit over the opt-in.
- **Mount the whole domain, audit the 19 dormant resources, don't suppress
  them.** Confirmed by the user directly. The audit (tasks.md) is the actual
  gate, not an attempt to avoid activation.
- **Flag, don't fix, the OAuth-scope gap.** It's real and it's made worse by
  this change, but fixing it is a pipeline-wide concern touching every
  currently-mounted domain, not something to smuggle into a proposal about
  alert rules. A GitHub issue captures it for a dedicated follow-up.
- **Regenerate and commit the OpenAPI dump manually, in this PR.** The only
  check for drift is a non-blocking nightly cron; don't rely on it.

## Risks / Trade-offs

- If the audit of the 19 dormant resources' read policies turns up one that
  genuinely defaults open (e.g. authorizes any authenticated actor to read
  data that should be role-gated), that resource needs its own policy fix
  before this change can safely mount the domain — treat as a blocking
  finding, not a footnote, if it happens.
- The scope-enforcement gap (Non-Goal, flagged not fixed) means this change
  is knowingly shipping a new mutation surface for a security-relevant
  resource without closing a known adjacent hole. Justified because the hole
  is pre-existing and platform-wide, not introduced here, but worth the
  reviewer's explicit sign-off, not a quiet acceptance.
- `policy_test_helpers.ex`'s generic 3-tier RBAC matrix assumes `operator`
  cannot `destroy`; `PresetRuleResource`'s actual policy
  (`operator_action([:create, :update, :destroy])`) grants operator destroy
  too. Reusing the generic matrix helper naively would assert the wrong
  thing — tests must cover destroy explicitly rather than trust the shared
  helper's baked-in assumption for this resource.

## Migration Plan

1. Land the macro opt-ins in `preset_rule_resource.ex`; add the regression
   test proving `StatefulAlertRuleTemplate`/`LogPromotionRule`/
   `LogPromotionRuleTemplate` get zero routes; confirm existing tests for
   those three still pass unchanged.
2. Add the extension + `:by_id` action + `json_api` block to
   `stateful_alert_rule.ex`.
3. Audit the 19 dormant resources' read policies (tasks.md checklist, one
   line per resource).
4. Mount `ServiceRadar.Observability` on `AshJsonApiRouter`; update its
   moduledoc.
5. Update `OpenApiV2Controller`'s `@domains`; file the separate
   pre-existing-`Notifications`-gap issue.
6. Regenerate and commit `priv/static/openapi.json`; strengthen the
   `GET /api/v2/open_api` test to assert the new path appears.
7. Write/extend the HTTP and policy test suites (tasks.md).
8. File the OAuth-scope-enforcement GitHub issue.

## Open Questions

- Should the audit in step 3 also produce a short doc comment on each of the
  19 resources noting "reachable via `/api/v2/*` as of this change" so a
  future reader doesn't have to rediscover that fact the hard way?
- Is there an appetite to make `OpenApiV2Controller` read
  `AshJsonApiRouter.domains()` directly instead of hand-maintaining a
  parallel list, as a follow-up? Would close this entire class of drift
  permanently rather than just fixing today's instance.
