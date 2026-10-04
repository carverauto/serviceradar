# Tasks

## 1. Data model
- [ ] 1.1 Add the embedded type `ServiceRadar.Identity.Homepage` (`kind`, `target_type`, `target_id`) with validation (D1)
- [ ] 1.2 `User`: add a `homepage` attribute and an `update_homepage_preference` action (self only, modeled on `update_timezone_preference`)
- [ ] 1.3 `UserGroup`: add `homepage` and `homepage_priority` (default 100), writable through the existing manage-gated update
- [ ] 1.4 `AuthorizationSettings`: add `default_homepage`
- [ ] 1.5 Migrations for the new columns, plus a data migration copying `dashboard_user_preferences.is_default` into `users.homepage` (D6)

## 2. Resolver
- [ ] 2.1 `ServiceRadarWebNG.Homepage.resolve/2` with the D2 precedence and D3 group ranking
- [ ] 2.2 Authorization check as the signing-in user for `:dashboard` targets (authored: scoped read; package: enabled and visible)
- [ ] 2.3 Wire it into `UserAuth.log_in_user/3`, `UserAuth.signed_in_path/1` and `PageController.home/2`; keep `return_to` precedence
- [ ] 2.4 One-time flash when an explicit user homepage falls through

## 3. UI
- [ ] 3.1 `/settings/profile`: a "Default homepage" control (inherit / overview / dashboards list / specific dashboard, with a searchable picker of dashboards the user can open)
- [ ] 3.2 `/settings/user-groups`: group homepage and priority controls (manage permission), the homepage shown on the group card, and an audience-visibility warning (D4)
- [ ] 3.3 Authorization settings: a deployment default homepage control, plus copy linking IdP mappings to group homepages (D7)
- [ ] 3.4 Dashboards hub: "Set as default" writes the user homepage (D6)

## 4. Tests
- [ ] 4.1 Resolver precedence: return_to > user > group > deployment > `/dashboard`
- [ ] 4.2 Group tie-break: priority, then name, then id; an unreadable group target is skipped before ranking
- [ ] 4.3 Fallback for a deleted or unreadable dashboard target at each level; flash only for the user level
- [ ] 4.4 SSO: a first sign-in through a mapped IdP group lands on the group homepage on the same request
- [ ] 4.5 Write-time validation rejects unknown kinds and unreadable or missing targets; there is no free-text path
- [ ] 4.6 RBAC: a non-manager cannot set a group homepage; users can only set their own
- [ ] 4.7 Data migration: an `is_default` row becomes `users.homepage`, and an existing homepage is not overwritten

## 5. Docs
- [ ] 5.1 Operator docs: homepage precedence, the group priority rule, and the SSO path
- [ ] 5.2 Release note for the D6 behavior change
