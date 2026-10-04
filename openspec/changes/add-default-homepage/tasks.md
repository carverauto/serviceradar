## 1. Implementation

- [x] 1.1 Migration `20261005150000` for `homepage_kind` and `homepage_target` on users and user groups, and Helm `core.migrations.expectedVersion`.
- [x] 1.2 `Identity.Homepage` resolver, check SQL, and `HomepagePreference` validation.
- [x] 1.3 `update_homepage_preference` on `User` (self-only) and `UserGroup` (`identity.user_groups.manage`).
- [x] 1.4 Profile control on `/settings/profile` and group control on `/settings/user-groups`.
- [x] 1.5 `UserAuth.login_destination/2` and SAML login params that omit a blank return path.
- [x] 1.6 Resolver tests and the db-free redirect and SSO ordering tests.
