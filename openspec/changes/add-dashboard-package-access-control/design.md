## Context

ServiceRadar has two kinds of dashboard, and only one of them has access control.

**Authored dashboards** are the SRQL dashboard builder's output. `AuthoredDashboard` carries
`owner_id` and `visibility` (`:private | :shared | :public`, default `:private`,
`authored_dashboard.ex:177-182`), and `DashboardAccessGrant` carries per-user and per-group grants
with a `[:view, :edit]` access level. Five policy check modules under
`lib/serviceradar/dashboards/checks/` enforce it: `ActorCanAccessDashboard`,
`ActorCanAccessDashboardChild`, `ActorCanEditDashboard`, `ActorCanEditDashboardChild` (all
`Ash.Policy.FilterCheck`) and `ActorCanEditDashboardTarget` (an `Ash.Policy.SimpleCheck`, because a
filter check cannot constrain a create -- there is no row yet).

**Package dashboards** are the CLI-published ones: a signed WASM or browser-module renderer plus a
validated JSON manifest, published through `POST /api/v1/dashboard-packages`, bound to a route by a
`DashboardInstance`, and served at `/dashboards/:route_slug`. `DashboardPackage` and
`DashboardInstance` declare no authorizer, no owner, and no visibility. They are world-readable to
every authenticated user.

Three structural facts constrain the design:

1. `dashboard_access_grants.dashboard_id` is **NOT NULL** and references
   `platform.authored_dashboards` with `ON DELETE CASCADE`
   (`20260521232025_create_dashboard_access_groups.exs:86-98`). Reusing that table for a second
   target type means dropping a NOT NULL constraint on a shipped table.
2. `DashboardInstance` has **no `owner_id`**. Any default-deny rollout that lacks an owner makes
   existing dashboards visible to nobody.
3. The Policy Editor derives the entire grid -- resource columns *and* action rows -- by string-
   splitting permission keys (`rbac_live.ex:899-910`). Presentation is therefore a hostage of key
   naming, which is why "fix the grid" and "rename the keys" look like the same problem and are not.

## Goals / Non-Goals

**Goals**

- A per-dashboard access decision for package dashboards, expressible by an admin in the Policy
  Editor and by a dashboard owner in a sharing dialog.
- One predicate enforced at every surface that can reveal a dashboard: route, hub listing, frame
  channel, renderer blob.
- Zero access change for any existing viewer at upgrade time.
- No permission key renamed or removed.

**Non-Goals**

- Row-level or column-level authorization of the *data* inside a dashboard. Frames already execute
  under the viewer's own scope (`FrameRunner.run/3`, `frame_runner.ex:21-45`); whatever SRQL
  authorization applies elsewhere applies here unchanged.
- Reworking authored-dashboard sharing. `add-dashboard-creator` owns that surface.
- A generic cross-resource `AccessGrant` table. See Decision 2.
- Changing `DashboardPackage` verification, signing, or the publish protocol.

## Decisions

### Decision 1 -- Grants attach to `DashboardInstance`, not `DashboardPackage`

The instance is the thing a user opens. It owns `route_slug`, `enabled`, `placement` and
`is_default`; a single package can back multiple instances; and publishing a new package version
under the same `dashboard_id` leaves the route -- and therefore the audience -- unchanged. Attaching
grants to the package would make "who may see the NOC map" a property of an artifact that gets
replaced on every publish.

*Consequence:* the renderer blob endpoint is keyed by package id, not instance id, so its
authorization is "the requester can view **at least one** instance backed by this package." That is
the honest predicate; a package with no viewable instance yields 404.

*Alternative considered:* grant on the package, resolve instances through it. Rejected -- it inverts
the lifetime relationship and makes a republish an access-control event.

### Decision 2 -- A sibling grant table, not a polymorphic `DashboardAccessGrant`, and not a generic `AccessGrant`

**Chosen: `DashboardInstanceAccessGrant`** -- a new resource and table with the same subject
vocabulary (`subject_type` in `[:user, :group]`, `subject_user_id`, `subject_group_id`, `access` in
`[:view, :edit]`, `granted_by_id`, `metadata`) and a NOT NULL FK to `dashboard_instances`.

| Option | For | Against |
|---|---|---|
| **A. Make `DashboardAccessGrant` polymorphic** (nullable `dashboard_id`, add `instance_id`, `target_type`) | One table, one sharing UI, one audit trail; users never learn the authored/package distinction | Drops a NOT NULL constraint on a shipped table; needs two nullable FKs plus a CHECK to keep referential integrity; every existing filter check is written against the `dashboard.` relationship (`dashboard.owner_id`, `dashboard.access_grants`) and would need a second branch; `ActorCanEditDashboardTarget` loads `AuthoredDashboard` by id and would need to dispatch on target type; couples this change's release to `add-dashboard-creator`'s in-flight work on the same resource |
| **B. Sibling table (chosen)** | No migration against a live grant table; FKs stay real and cascade correctly; each resource's policy block stays short enough to read; `DashboardInstance` gains an authorizer without touching `AuthoredDashboard`; ships independently | Two tables and two sharing dialogs to keep in step; "everything shared with me" needs a union; duplicated check modules are a genuine drift risk |
| **C. Generic `Identity.AccessGrant` (subject x resource_type x resource_id)** | One model for all future sharing | Loses FK integrity by construction; requires migrating a shipped table; and it contradicts the direction already set by `add-device-group-grants`, which deliberately introduces a *per-resource* grant join (`Identity.DeviceGroupGrant`) rather than a generic one |

Option B's one real cost -- drift between two copies of the same predicate -- is mitigated directly:
the `subject_type == :user and subject_user_id == ^actor_id` / group-membership expression, which
today appears verbatim in five modules, is extracted into a single
`ServiceRadar.Dashboards.Checks.SubjectGrant` helper that both the authored and instance checks
call. The repo-wide rule against a second implementation of a shared primitive applies here: one
expression, two call sites, not two expressions.

If a third shareable resource appears, revisit Option C as its own change -- with `DeviceGroupGrant`
and both dashboard grants as the three inputs to that design, rather than guessing now.

### Decision 3 -- Catalog metadata, aliases; no key renames

The Policy Editor's Dashboards tab is broken in three separate ways, and only one of them is about
naming:

1. Action rows are global to the whole catalog, so every section shows all 44 actions
   (`rbac_live.ex:851-856` + `section_grid/2`, `:1147-1164`).
2. Resource labels are derived by stripping the section prefix, which fails whenever the key's
   namespace differs from its section (`resource_short_label/2`, `:920-926`) -- hence the literal
   header `cli.dashboard` under the "Dashboards" tab.
3. Dashboard permissions are split across two sections because the section is inferred from the key.

Renaming `cli.dashboard.*` to `dashboards.packages.*` fixes only (3), and costs: five hardcoded
strings (`router.ex:191`, `dashboard_package_publish_controller.ex:67,129,177,341`), a user-facing
CLI error message (`js/cli/src/dashboard/publish.ts:175`), and a data migration over every role
profile's permission array. Fixing the grid fixes (1) and (2) for **all** 33 of the 44 catalog
actions that currently fall outside `@action_order` -- including the empty-string action row that
three colon-separated keys produce (`catalog.ex:526-538`) -- not just dashboards.

So: fix the grid, and give catalog entries explicit `section` / `resource` / `action` metadata so
presentation stops depending on the key at all. The canonical `dashboards.packages.publish|enable|
disable` names are introduced as **aliases**, resolved as equivalent in both directions at check
time: a profile holding either key passes a check for either key. Nothing is rewritten, nothing
breaks, and a later cleanup can retire the old spelling once no profile carries it.

*Alternative considered:* rename with a one-way deprecation shim and a profile backfill. Rejected for
now -- it is a data migration bought purely for cosmetics, and the cosmetics are already fixed by the
grid work. The alias table is the forward-compatible half of that plan, kept.

### Decision 4 -- Enforce in Ash, verify at each surface

Every gate resolves to the same Ash read policy on `DashboardInstance`. Surfaces do not re-implement
the predicate; they call the authorized read and handle `{:error, :not_found}` /
`Ash.Error.Forbidden`. This matters because the four surfaces have four different actors-in-hand: a
LiveView socket assign, a channel socket, a `Plug.Conn`, and an async task. A predicate written four
times is a predicate that will be wrong in one of them.

The frame channel gets two extra requirements beyond the shared read, because a signed token is
currently a bearer credential:

- the stream token payload gains the minting user's id, verified against the joining socket's user;
- the join re-derives current authority with `RBAC.authorize_current/2` (`rbac.ex:64-72`) instead of
  trusting the socket's cached permission `MapSet`, so a grant revoked mid-session cannot be ridden
  out for the token's remaining lifetime.

### Decision 5 -- A `:view` grant is not a query-execution grant

`?q=<srql>` and `?frame_<id>=<srql>` replace a manifest's declared frame query (`show.ex:528-545`,
`565-578`), and the rewritten frames are then signed into the stream token (`show.ex:487-492`). That
means the dashboard route is a general SRQL execution surface, not merely a renderer for vetted
queries. It executes as the viewer, so it is not privilege escalation -- but "may see the NOC
dashboard" must not silently mean "may run arbitrary SRQL." Overrides stay gated on the viewer's own
analytics query permission; a view-only grantee gets the packaged frames and no override.

## Risks / Trade-offs

- **Two grant models drift apart.** -> One shared `SubjectGrant` expression module; a test asserts the
  authored and instance checks produce the same decision for an equivalent fixture.
- **A default-deny flip in a later release blacks out a deployment.** -> The default lives in a
  deployment setting, ships as `public`, and `dashboards.packages.view_all` is an admin-default
  bypass. The flip is its own change with its own CHANGELOG entry.
- **A migration that adds `visibility` with the wrong default is a silent outage.** -> The migration
  backfills existing rows explicitly rather than relying on a column default, and the verification
  step queries for rows where `visibility <> 'public'` after backfill and fails if any exist. A
  check that can only confirm success is not a check.
- **The Policy Editor reorganization confuses admins mid-upgrade.** -> Keys are unchanged, so saved
  profiles are unaffected; only the tab a checkbox appears on moves. The `Unmapped permissions`
  panel (`rbac_live.ex:736-746`) already surfaces anything the catalog stops describing, which is
  the backstop if a metadata entry is missed.
- **Renderer 404 for a package with no viewable instance looks like a broken deploy.** -> The
  controller already returns 404 for unavailable renderers; the audit event distinguishes
  `not_found` from `forbidden` so an operator can tell the two apart from the log.

## Migration Plan

1. Ash codegen adds `visibility` (default `:public` at the column level for this release),
   `owner_id` (nullable), and the `dashboard_instance_access_grants` table.
2. The same migration backfills `visibility = 'public'` on all existing `dashboard_instances` rows
   and leaves `owner_id` NULL. Post-migration assertion: zero rows with `visibility <> 'public'`.
3. Ship enforcement with the deployment default at `public`. The model is live and inert: grants can
   be created, nothing is denied that was previously allowed.
4. Publishers begin recording `owner_id` on newly created instances.
5. Deployments opt into `private` per instance, or flip
   `dashboards.packages.default_visibility` when ready.
6. **Rollback:** the enforcement is a read policy plus four call-site changes; reverting the release
   restores world-readability without a schema change. The new table and columns are additive and
   can be left in place across a rollback.

## Open Questions

- Should `dashboards.packages.share` be grantable to a dashboard's `owner_id` implicitly (as
  `ActorCanEditDashboardTarget` does for authored dashboards), or always require the explicit
  permission? Proposed: implicit for the owner, matching the authored path.
- Should the hub show a placeholder row for a dashboard the viewer cannot open, or omit it entirely?
  Proposed: omit -- a placeholder leaks the existence and name of a restricted dashboard.
- Does `is_default` (`dashboard_instance.ex:102-106`) need a fallback when a user's default dashboard
  becomes invisible to them? Proposed: fall back to the hub with a flash, not a hard error.
