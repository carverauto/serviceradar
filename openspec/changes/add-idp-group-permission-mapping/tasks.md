# Tasks

## 1. Mapping shape

- [x] 1.1 Extend the `role_mappings` entry shape in `AuthorizationSettings` with an optional
      `role_profile_id` and an optional `user_group_id`, keeping `role` optional-but-present for
      existing entries.
- [ ] 1.2 Add validation: an entry must name at least one of `role`, `role_profile_id`,
      `user_group_id`; referenced ids must exist at write time.
- [ ] 1.3 Migration for the new entry shape. Existing entries must round-trip unchanged.
- [x] 1.4 Update `RoleMappingSupport` accessors for the new keys.
      DONE: `RoleMappingSupport` gains `role_rank/1`, `highest_role/1`, `presence/1`. Ranking is explicit because atom comparison sorts :admin below :helpdesk.

## 2. Resolution

- [x] 2.1 Replace `RoleMapping.resolve_role/2`'s `Enum.find_value` first-match with a resolver that
      DONE: `match_mappings/2` filters rather than `find_value`, so every match contributes.
      collects **every** matching mapping.
- [x] 2.2 Return a resolution struct — matched mappings, resulting role, profile ids, group ids —
      DONE: `resolve/2` returns `%{role, role_profile_ids, user_group_ids, matched}`.
      rather than a bare role atom, so callers and the dry-run surface share one code path.
- [x] 2.3 Union the permission sets of all matched profiles; apply the highest matched role.
      DONE: Profile and group ids union; role is the highest matched by `role_rank/1`.
      Define the role ordering explicitly rather than relying on atom comparison.
- [x] 2.4 Keep `resolve_role/2` as a thin wrapper for any caller that only wants the role.
- [ ] 2.5 Decide and implement the no-match case: fall back to `default_role` and clear
      IdP-granted profiles, or retain the prior profile. See the proposal's open question.
- [ ] 2.6 Preserve the existing "do not demote an existing `:admin`" guard
      (`sso_provisioning.ex:108-110`) under union semantics, and state the rule in a comment.

## 3. SSO application

- [x] 3.1 Apply `role_profile_id` in `SSOProvisioning`, which today never writes it.
      DONE: `maybe_update_role_profile/3` applies the resolved profile. A mapping pointing at a deleted profile logs and leaves the user's access unchanged rather than failing the login.
- [x] 3.2 Apply IdP-managed `UserGroup` memberships; add an `idp_managed` marker to
      DONE: `source` marker on UserGroupMembership (:manual | :idp) with migration 20260830130000, plus `IdpGroupMemberships.sync/3` called from SSO on every sign-in.
      `UserGroupMembership` and a migration for it.
- [x] 3.3 Withdraw IdP-managed memberships whose claim no longer arrives; never touch
      DONE: Withdrawal covers only :idp rows. A membership an operator created is never touched -- 'the claim did not arrive' is not evidence an operator's decision was wrong. A group already added manually is also not converted to :idp, which would make it withdrawable.
      operator-created memberships.
- [x] 3.4 Record the matched mapping set on the user's last authentication so an operator can see
      DONE: `UserAuthEvents.record_role_mapping/3` writes a `role_mapping` event carrying the resolved role, profile/group ids and the matched mappings. Claim payloads are deliberately NOT recorded -- a claim set carries far more about a person than the decision needs.
      why a user has the access they have.
- [x] 3.5 Ensure the RBAC permission cache is invalidated when a sign-in changes a user's profile —
      DONE: Already handled by the resource: `update_role_profile` carries `change InvalidateUserRbacCache`.
      `RBAC.permissions_for_user/2` caches in the process dictionary and ETS.

## 4. Operator surfaces

- [ ] 4.1 Add a role-profile selector and a user-group selector to the mapping editor in
      PARTIAL: the mappings editor is a raw JSON textarea, so a selector would mean
      rebuilding it. Added a collapsible list of role profiles and user groups with their ids
      instead, so an operator can copy one rather than hunt for it on another page. A structured
      editor is still the better answer and is not done.
      `authorization_live.ex`.
- [x] 4.2 Add the dry-run resolver: paste a claim set, see matched mappings, role, profile and the
      DONE: Dry-run resolver on Settings -> Authorization: paste a claim set, see the resolved role, profiles, groups and which mappings matched, without signing anyone in.
      resulting permission set.
- [x] 4.3 Warn when a `groups`-source mapping exists while the configured OIDC scopes omit
      DONE: Warns when a `groups`-source mapping exists while the configured OIDC scopes omit groups -- otherwise those mappings silently match nothing and look broken rather than unscoped.
      `groups` (`oidc_strategy.ex:72` defaults to `openid email profile`).
- [ ] 4.4 Show the last-login matched mappings on the user detail surface.
- [ ] 4.5 Update the authorization settings API and `openapi/admin_spec.ex` for the new entry shape.

## 5. Docs

- [x] 5.1 Document the mapping model under `docs/docs/`: sources, precedence, union semantics, and
      the difference between a role and a profile. ASCII only.
      DONE: `docs/docs/group-permission-mapping.md` -- sources, precedence, union, revocation,
      and when to reach for a profile rather than a role. Linked from `auth-configuration.md` and
      registered in `docs/sidebars.ts` (the sidebar is explicit, not autogenerated).
- [x] 5.2 Document Microsoft Entra specifically: how to emit the groups claim, that it carries group
      **object IDs** unless the app registration is configured for names, and the group-overage
      behaviour that replaces the claim with a Graph pointer for large directories.
      DONE: object IDs vs display names, the `groups` scope, and overage. Overage is called out
      as hard to spot: it hits only users in many groups, so most sign-ins keep working while the
      affected user silently drops to the default role.
- [x] 5.3 Worked example: an Entra group bound to a profile holding `plugins.stage`, which is what
      makes CLI plugin publishing grantable to a team.
      DONE: Entra group -> `Plugin Authors` profile. The profile grants `plugins.view` AND
      `plugins.stage` (staging without view would publish blind) and deliberately not
      `plugins.approve`, keeping publish and approve separate.

## 6. Tests

- [x] 6.1 Resolver: single match; multiple matches union; order independence; no match; unknown
      profile id; role-only entry unchanged.
      DONE: `idp_group_permission_mapping_db_test.exs` covers single match, union across
      several matches, order independence, no-match fallback and role-only entries. An id naming a
      deleted profile is covered at the apply site instead of the resolver -- the resolver never
      dereferences it.
- [x] 6.2 Role precedence: highest matched role applied; admin not demoted.
      DONE: same file. The precedence test uses operator/admin/helpdesk together, which is the
      case a naive `Enum.max` on atoms gets wrong (`:admin` sorts below `:helpdesk`).
- [x] 6.3 SSO: profile applied on create and on subsequent login; permission cache invalidated.
      DONE: `sso_provisioning_test.exs` covers apply on first sign-in and revoke on the next
      sign-in once the group is gone, plus a manually assigned profile surviving a no-match.
- [x] 6.4 Group membership: created from claim, withdrawn when claim disappears, operator-created
      membership retained.
      DONE: covered on both sides -- `IdpGroupMemberships.sync/3` directly in core, and through a
      real sign-in in web-ng. Operator-created memberships are asserted untouched in both.
- [ ] 6.5 Dry-run resolver returns the same result as a real sign-in for the same claims.
- [ ] 6.6 LiveView: profile selector persists; missing-scope warning renders.
- [ ] 6.7 Migration round-trips existing role-only mappings.

## 7. Verification

- [ ] 7.1 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix`
- [ ] 7.2 `./scripts/elixir_quality.sh --project elixir/serviceradar_core`
- [ ] 7.3 `make test`
- [ ] 7.4 `openspec validate add-idp-group-permission-mapping --strict`
