# Design: Configurable default homepage

## Context

The sign-in redirect is hard-coded in three places:

- `UserAuth.log_in_user/3` falls back to `~p"/dashboard"` when there is no
  `user_return_to`.
- `UserAuth.signed_in_path/1` returns `/dashboard`.
- `PageController.home/2` redirects an authenticated `/` to `/dashboard`.

All OIDC, SAML, password and gateway sign-ins funnel through `log_in_user/3`.

The pieces this design builds on:

- **Dashboards are addressed** at `/dashboards/:route_slug`. Authored dashboards resolve
  by `dashboard_ref` or slug; package instances resolve by `route_slug`.
- **Read access** to an authored dashboard is the `AuthoredDashboard` read policy
  (`dashboards.view`, plus `view_all` or `ActorCanAccessDashboard`, which covers owner,
  public visibility, user grants and group grants). Package instances have their own
  enabled/visibility rules.
- **`DashboardUserPreference`** already stores a per-user default marker
  (`target_type` of `:authored | :package`, plus `target_id`). It is set from the
  dashboards hub, but no code path uses it for navigation.
- **SSO ordering:** `SSOProvisioning.find_or_create_user/4` runs
  `IdpGroupMemberships.sync/3` before the controller calls `log_in_user/3`, so
  membership changes from the current sign-in are committed before the redirect is
  computed.

## Goals / Non-Goals

**Goals:**
- Deterministic precedence.
- No open redirect.
- Authorization re-checked at redirect time.
- SSO users routed by group on their first sign-in.
- One "my default" concept per user.

**Non-goals:**
- A forced homepage that users cannot override.
- Arbitrary routes or free-text URLs.
- Per-tenant behavior.
- New IdP claim types.

## Decisions

### D1. A homepage is a typed choice, never a URL

The shared embedded type `ServiceRadar.Identity.Homepage` holds:

- `kind`: one of `:overview`, `:dashboards_index` or `:dashboard`.
- `target_type`: `:authored` or `:package`. Required only when `kind` is `:dashboard`.
- `target_id`: the authored dashboard UUID or package route slug. Required only when
  `kind` is `:dashboard`.

The default state is "inherit", meaning the attribute is nil. The path comes from a
single function, `Homepage.path/1`, and each kind maps to a route that is a compile-time
constant or a dashboard route built with `~p`. No user-supplied string is ever
redirected to, so the open-redirect class from the issue cannot occur.

New kinds, such as other allowlisted app routes, are added by extending the enum and
`path/1`. Validation rejects any unknown kind.

### D2. Precedence, evaluated by one resolver

`ServiceRadarWebNG.Homepage.resolve(conn_or_scope, user)` returns the first
candidate that passes:

1. A sanitized `user_return_to` or `return_to`. The existing `sanitize_return_path/1`
   behavior is unchanged; deep links always beat homepages.
2. The user homepage.
3. The group homepage chosen by D3.
4. The deployment default from `AuthorizationSettings`.
5. `/dashboard`.

The `:overview` and `:dashboards_index` kinds always pass; those routes do their own
RBAC.

A `:dashboard` candidate passes only when it is readable **as the signing-in user's
scope at that moment**. For an authored dashboard, that means a scoped read through the
normal policy. For a package instance, it means it is enabled and visible to the actor.
A candidate that fails is skipped silently, and the resolver moves to the next level.
When an explicitly chosen *user* homepage is skipped, the redirect carries a one-time
info flash ("Your homepage dashboard is no longer available; showing the default").
Group and deployment fall-throughs are not flashed, because the user did not choose
them.

`log_in_user/3`, `signed_in_path/1` and `PageController.home/2` all call the resolver.
Other "home" links, such as the logo, keep pointing at `/`, which now resolves through
`PageController.home/2`.

### D3. Multi-group conflicts: explicit priority, then name, then id

Each `UserGroup` gains `homepage_priority`, a non-null integer defaulting to 100 where
lower wins. Among the user's groups that have a homepage set *and pass the D2
authorization check*, the resolver picks the one with the lowest `homepage_priority`,
breaking ties by `lower(name)` and then `id`.

Why explicit priority:
- **IdP assignment order is not stable.** Claim arrays are unordered, and a re-sync
  rewrites membership rows.
- **Name order alone is surprising.** Renaming a group silently changes where people
  land.

Operators who never set priorities get the name order, which is deterministic and
documented. Groups whose dashboard the user cannot read are skipped *before* ranking,
so a broken high-priority group does not mask a working lower-priority one.

### D4. Write-time validation

When a user, group or deployment homepage of kind `:dashboard` is saved, the target
must exist and be readable by the **actor saving it**.

For a group or deployment homepage, the UI warns, without blocking the save, when the
dashboard is not visible to the whole audience. That is the case when the dashboard is
neither public nor granted to that group. Members who cannot read it fall through at
redirect time, per D2.

The dashboard picker lists the dashboards the actor can open, which is the same
listing the dashboards hub uses.

### D5. RBAC

| Action | Permission |
|---|---|
| Set or clear your own homepage | Authenticated user acting on themselves (new `update_homepage_preference` action, modeled on `update_timezone_preference`) |
| Set or clear a group homepage and `homepage_priority` | `identity.user_groups.manage` (existing `UserGroup` update policy; no new permission) |
| Set the deployment default | The existing `AuthorizationSettings` manage permission |

Reading for resolution happens under a system actor scoped to the deployment, with
the authorization check of D2 still applied *as the user*. The system actor only reads
the preference rows, never the dashboard.

### D6. One per-user default: the hub's "Set as default" writes the user homepage

`DashboardUserPreference.is_default` and a new user homepage would otherwise be two
competing "defaults". So the hub's "Set as default" action writes
`User.homepage = %{kind: :dashboard, ...}`, and the profile page shows the same value.

A data migration copies each user's single `is_default` preference into
`User.homepage` when the user has none. The column is then left unused and removed in a
follow-up after one release.

Consequence: a user who previously marked a hub default will **start landing on that
dashboard after sign-in**. That matches what the button says. The release notes call it
out.

### D7. SSO

There is no new claim plumbing. An operator maps an IdP group to a `UserGroup` in the
existing authorization settings and sets that group's homepage. Because membership sync
completes before `log_in_user/3`, D2 sees the new membership on the first sign-in.

Two pieces of UI copy make this explicit:
- **Group card:** "Users mapped from IdP group X land on Y via this group."
- **Authorization page:** links each mapping to its group's homepage.

## Risks / Trade-offs

- **An extra query per sign-in.** It is bounded: one user read, one read of the user's
  groups that have a homepage, the singleton, and at most one authorization check per
  candidate. It runs only on sign-in and `/`, never on LiveView navigation.
- **D6 changes behavior for existing hub-default users.** This is mitigated by the
  release note. The alternative, keeping two concepts, was rejected as confusing.
- **Stale targets after a dashboard is deleted.** D2 handles them at read time. No
  cascade is needed, and saved preferences pointing at missing targets are harmless.

## Migration Plan

1. Add `users.homepage` (jsonb, null), `user_groups.homepage` (jsonb, null),
   `user_groups.homepage_priority` (integer, not null, default 100) and
   `authorization_settings.default_homepage` (jsonb, null).
2. Copy each `is_default` preference into `users.homepage` where it is null.
3. Ship the resolver and UI.
4. In a follow-up release, drop `dashboard_user_preferences.is_default`.

Rollback: the new columns are additive. Removing the resolver restores `/dashboard`.

## Open Questions

None that block implementation. A "force deployment homepage" flag is a possible
follow-up.
