# Tasks

## 1. Data model
- [x] 1.1 Add the embedded type `ServiceRadar.Identity.Homepage` (`kind`, `target_type`, `target_id`) with validation (D1). Implemented as a canonical string-keyed `jsonb` map with `normalize/1`, written only through a `:homepage` action argument so atomic updates still see the value; DB check constraints mirror the allowed kinds.
- [x] 1.2 `User`: add a `homepage` attribute and an `update_homepage_preference` action (self only, modeled on `update_timezone_preference`)
- [x] 1.3 `UserGroup`: add `homepage` and `homepage_priority` (default 100), writable through the existing manage-gated update (a dedicated `update_homepage` action under the same `identity.user_groups.manage` check, so saving a group's name never touches its homepage)
- [x] 1.4 `AuthorizationSettings`: add `default_homepage`
- [x] 1.5 Migrations for the new columns, plus a data migration copying `dashboard_user_preferences.is_default` into `users.homepage` (D6)

## 2. Resolver
- [x] 2.1 `ServiceRadarWebNG.Homepage.resolve/2` with the D2 precedence and D3 group ranking
- [x] 2.2 Authorization check as the signing-in user for `:dashboard` targets (authored: scoped read; package: enabled and visible)
- [x] 2.3 Wire it into `UserAuth.log_in_user/3`, `UserAuth.signed_in_path/1` and `PageController.home/2`; keep `return_to` precedence
- [x] 2.4 One-time flash when an explicit user homepage falls through

## 3. UI
- [x] 3.1 `/settings/profile`: a "Default homepage" control (inherit / overview / dashboards list / specific dashboard, with a searchable picker of dashboards the user can open; a native select with type-ahead, loaded after connect)
- [x] 3.2 `/settings/user-groups`: group homepage and priority controls (manage permission), the homepage shown on the group card, and an audience-visibility warning (D4)
- [x] 3.3 Authorization settings: a deployment default homepage control, plus copy linking IdP mappings to group homepages (D7)
- [x] 3.4 Dashboards hub: "Set as default" writes the user homepage (D6)

## 4. Tests

Owners: `ServiceRadar.Identity.HomepageDbTest` (4.5, 4.6) and `ServiceRadarWebNG.HomepageTest` (4.1-4.4, D6). Proof for this change is PR BazelCI, by the user's decision.
- [x] 4.1 Resolver precedence: return_to > user > group > deployment > `/dashboard`
- [x] 4.2 Group tie-break: priority, then name, then id; an unreadable group target is skipped before ranking
- [x] 4.3 Fallback for a deleted or unreadable dashboard target at each level; flash only for the user level
- [x] 4.4 SSO: a first sign-in through a mapped IdP group lands on the group homepage on the same request
- [x] 4.5 Write-time validation rejects unknown kinds and unreadable or missing targets; there is no free-text path
- [x] 4.6 RBAC: a non-manager cannot set a group homepage; users can only set their own
- [x] 4.7 Data migration: an `is_default` row becomes `users.homepage`, and an existing homepage is not overwritten (the migration is idempotent and reversible and only fills users with no homepage; `HomepageDbTest` reruns `backfill_sql/0` and checks both cases. `down` drops the new columns and leaves `is_default` in place)

## 5. Docs
- [x] 5.1 Operator docs: homepage precedence, the group priority rule, and the SSO path
- [ ] 5.2 Release note for the D6 behavior change (the CHANGELOG has no unreleased section; the note is in the PR body for the release cut)
