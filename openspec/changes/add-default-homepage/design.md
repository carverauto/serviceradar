## Context

Sign-in already stores `user_return_to` and passes an optional `return_to` into `UserAuth.log_in_user/3`. Password login leaves that session value alone. OIDC does the same. SAML used to fill a missing return path with `/dashboard`, which would hide any homepage.

`DashboardUserPreference.is_default` is the star on a dashboard card. Login ignores it. This change does not add a second preference store.

## Goals / Non-Goals

- Goals: a per-user and per-group homepage, a fixed precedence, a safe redirect, and a settings control for each.
- Non-Goals: a free-text URL, a deployment-wide forced homepage, auto-sharing a dashboard because it was picked, and changing the `/flows` dashboard.

## Decisions

- Decision: store `homepage_kind` and `homepage_target` on `User` and `UserGroup`. Null kind on a user means inherit. Null kind on a group means that group sets nothing. Kinds are `platform`, `dashboards`, `authored`, and `package`. Only `authored` and `package` have a target, and the target matches `^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$`.
- Decision: `update_homepage_preference` is its own action on each resource, with `accept []` and two arguments. The fields stay off the general profile, admin, and group update accepts.
- Decision: the user's action is self-only, same shape as the timezone preference, and the caller passes `scope:`. The group action requires `identity.user_groups.manage`.
- Decision: precedence is the user's explicit choice, then groups ordered by membership `inserted_at` descending, then group name ascending, then `/dashboard`. An identity-provider refresh does not move `inserted_at`. Withdrawing and adding the member again is a new assignment.
- Decision: the redirect loads memberships with `SystemActor.system(:homepage_redirect)`. A normal user may lack `identity.user_groups.view`. A lookup error yields no groups and does not fail sign-in.
- Decision: the logging-in user must still be able to open an authored dashboard (`status == :active`) or an enabled package. The picker lists only dashboards that actor can already open, capped at 100. Draft and archived dashboards are unpublished.
- Decision: a non-blank return path is sanitized and used as-is. Sanitizing an unsafe path to `/dashboard` does not then call the homepage resolver.
- Decision: the fallback notice is appended to the existing "Signed in" info flash. `signed_in_path/1` returns only a path, so an already signed-in visit does not add that notice.
- Alternatives considered: metadata maps (easy to miss in policies and constraints), and reusing `DashboardUserPreference` (that flag is per dashboard card, not the sign-in route, and it is not a group setting).

## Risks / Trade-offs

- A group homepage can name a dashboard the member cannot open. The redirect falls through. The group page says that choosing a dashboard does not share it.
- The settings catalog is a select capped at 100. A larger estate still saves an id that is missing from the list; the control keeps that saved id labeled "Saved dashboard".
- The profile token-confirmation mount does not assign homepage fields. It navigates away, matching the existing timezone mount.

## Migration Plan

Add the nullable columns and the check constraints. No row rewrite. Rollback drops the constraints, then the columns.

## Open Questions

None.
