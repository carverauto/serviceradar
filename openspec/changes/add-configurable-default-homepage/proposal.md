# Change: Configurable default homepage (user, user group, deployment)

## Why

Every authenticated user lands on `/dashboard` after sign-in. `UserAuth.log_in_user/3`
falls back to a hard-coded `~p"/dashboard"`, and so does `PageController.home/2` for
`/`. Teams that author a dashboard for a role (a NOC wall, a security
view) cannot send that audience to it, and SSO users cannot be routed by IdP group.
GitHub issue #5001.

The building blocks already exist. `DashboardUserPreference.is_default` lets a user
mark one dashboard as their default from the dashboards hub, but that mark only affects
hub ordering and never drives sign-in. User groups exist, and SSO already syncs
IdP-mapped group memberships on every sign-in *before* the session is created, so a
group-level setting is visible on the same request.

## What Changes

- **Homepage value.** A homepage is a closed, typed choice and never a stored URL. It
  is either `overview` (`/dashboard`), `dashboards_index` (`/dashboards`), or `dashboard`
  plus a typed target (an authored dashboard id, or a dashboard package route slug). The
  server derives the path from that choice, so there is no open-redirect surface.
- **Per-user homepage.** It is set on `/settings/profile`. The dashboards hub's existing
  "Set as default" action writes the same value, so there is one "my default"
  concept rather than two. Existing `is_default` dashboard marks migrate into it.
- **Per-group homepage.** It is set on `/settings/user-groups` by holders of
  `identity.user_groups.manage`. Each group also gets an integer `homepage_priority`
  that decides between conflicting groups.
- **Deployment default homepage.** It is stored on the existing `AuthorizationSettings`
  singleton and managed with the existing auth-settings permission.
- **One resolver** replaces the hard-coded fallbacks in `log_in_user/3`,
  `PageController.home/2` and `signed_in_path/1`. The order is: a sanitized
  `return_to`/deep link, then the user homepage, then the best group homepage, then
  the deployment default, then `/dashboard`. The resolver re-checks read access to a
  dashboard target as the signing-in user at redirect time, and falls through to the
  next level when the target is gone or unreadable.
- **SSO** needs no new claim plumbing. An operator maps an IdP group to a user group and
  sets that group's homepage. Membership sync already runs before the redirect.

## Impact

- New capability spec: `user-homepage`.
- Code:
  - `ServiceRadar.Identity.User`: new homepage attribute and action.
  - `ServiceRadar.Identity.UserGroup`: homepage and `homepage_priority` attributes.
  - `ServiceRadar.Identity.AuthorizationSettings`: deployment default.
  - `ServiceRadar.Dashboards.DashboardUserPreference`: `is_default` retired after the
    data migration.
  - web-ng: `UserAuth`, `PageController`, `UserLive.Settings`, `Settings.UserGroupsLive`,
    the authorization settings page, and `DashboardHubLive.Index`.
- Migrations: three column additions, plus one data migration from
  `dashboard_user_preferences.is_default` into the user homepage.
- Out of scope:
  - A forced deployment homepage that users cannot override.
  - Free-text URLs.
  - Changes to the IdP mapping UI beyond copy that explains the group-to-homepage
    path.
  - Multitenancy: this stays a single-deployment setting.
