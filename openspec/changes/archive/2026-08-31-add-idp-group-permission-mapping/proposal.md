# Change: Map IdP group claims to permission sets, not just to a coarse role

## Why

**Claim-to-role mapping already exists, and it stops one level short of being useful.**
`ServiceRadar.Identity.RoleMapping.resolve_role/2`
(`elixir/serviceradar_core/lib/serviceradar/identity/role_mapping.ex`) reads
`AuthorizationSettings.role_mappings`, matches a `groups` or `email_domain` source against the
IdP's claims, and returns a role. `SSOProvisioning.find_or_create_user/4`
(`elixir/web-ng/lib/serviceradar_web_ng_web/auth/sso_provisioning.ex:31`) calls it on every OIDC
and SAML login and applies the result to `user.role`. Operators configure the mappings in
Settings -> Authorization (`live/settings/authorization_live.ex`).

What it cannot do is bind an IdP group to a **permission set**. Three specific gaps:

1. **Mappings resolve to the coarse `role` enum and never to a `RoleProfile`.** `RoleProfile`
   (`identity/role_profile.ex`) is where fine-grained permissions live — it is the resource an
   admin clones and edits to build, say, a profile holding `plugins.stage` but not
   `plugins.approve`. Nothing in the SSO path writes `user.role_profile_id`; a grep across
   `web-ng/lib/serviceradar_web_ng_web/auth/` returns no reference to it at all. So an operator can
   build exactly the permission set they want and then has no way to say "the Entra group
   `SR-Plugin-Authors` gets it". They are limited to admin/operator/viewer.

2. **First match wins, and a user gets exactly one role.** `match_mappings/2` uses
   `Enum.find_value`, so a user in three mapped Entra groups receives whichever mapping happens to
   be listed first. There is no union of permissions and no operator-visible precedence — reordering
   a list silently changes who can do what.

3. **Group claims never reach `UserGroup`.** `UserGroup`/`UserGroupMembership`
   (`identity/user_group.ex`) back access grants — dashboard sharing, device group grants — and are
   maintained entirely by hand. An IdP group and the ServiceRadar group of the same name are two
   unrelated lists that drift.

**This blocks the plugin work directly.** `add-cli-plugin-publish` adds a `plugin.publish` scope
whose use still requires the `plugins.stage` permission. Today granting that to a team means editing
each user, or promoting them to a role far broader than the task needs. With group-to-profile
mapping, "these developers may publish plugins" becomes one Entra group bound to one profile.

**One adjacent detail worth fixing here.** The default OIDC scope list is
`["openid", "email", "profile"]` (`auth/oidc_strategy.ex:72`). It is configurable, but `groups` is
not requested by default, so an operator who configures a `groups` mapping and never widens the
scopes gets silent no-matches and falls through to `default_role`. Entra additionally emits group
**object IDs** rather than names unless the app registration is configured otherwise, which makes a
mapping written against a human-readable group name fail the same silent way.

## What Changes

- **`role_mappings` entries may target a role profile** in addition to a role: a new optional
  `role_profile_id` (or profile name) on each mapping entry. When present, SSO sets
  `user.role_profile_id`, which is what actually determines the permission set.
- **Multiple matches resolve by union, not by first-match.** All matching mappings contribute; the
  resulting permission set is the union of their profiles, with the highest matched role applied to
  `user.role`. Deterministic and independent of list order.
- **Optional `UserGroup` synchronisation.** A mapping may additionally place the user in a
  ServiceRadar `UserGroup`, so IdP groups can drive access grants instead of a parallel hand-kept
  list. Memberships created this way are marked IdP-managed and are removed when the claim stops
  arriving.
- **Settings -> Authorization surfaces profiles and precedence**: the mapping editor gains a profile
  selector, shows which mappings matched at the last login for a given user, and warns when a
  `groups` mapping exists while the configured OIDC scopes omit `groups`.
- **A dry-run resolver** an admin can paste a claim set into, showing which mappings match, the
  resulting role, profile and permission set — so a mapping can be verified without a login attempt.
- **Docs** covering Entra specifically: requesting the groups claim, group object IDs versus names,
  and the group-overage claim that replaces `groups` with a Graph pointer for large directories.

**BREAKING**: none by default. Existing mappings carry no `role_profile_id` and keep resolving to a
role exactly as they do now. The union semantics change the outcome only where more than one mapping
matches, which today silently depends on list order.

## Tracking

GitHub issue: https://github.com/carverauto/serviceradar/issues/4146

## Impact

- **Affected specs**: `ash-authorization`
- **Affected code**:
  - `elixir/serviceradar_core/lib/serviceradar/identity/role_mapping.ex`,
    `role_mapping_support.ex`, `authorization_settings.ex`, `role_profile.ex`,
    `user_group_membership.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/sso_provisioning.ex`,
    `auth/oidc_strategy.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authorization_live.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/authorization_settings_controller.ex`,
    `openapi/admin_spec.ex`
  - A migration for the mapping shape and IdP-managed group memberships
- **Relationship to `add-cli-plugin-publish`**: independent, but this is what makes
  `plugins.stage` grantable to an IdP group rather than per-user. Not a prerequisite — that change
  ships without it.

## Open Questions

- Should an admin whose role was granted by an IdP mapping be demotable locally, or should the
  mapping always win on next login? `apply_role_mapping/3` currently refuses to demote an existing
  `:admin` (`sso_provisioning.ex:108-110`); union semantics need the same guard decided explicitly.
- ~~Should a user who matches no mapping keep their previous profile?~~ **DECIDED: removal from
  the group revokes the grant.** Implemented with a `role_profile_source` column so revocation
  applies only to IdP-granted profiles -- clearing unconditionally would also wipe a profile an
  operator assigned by hand to a user with no mapping.
- Entra group overage (>150-200 groups) replaces the claim with a Graph API pointer. Do we resolve
  it via Graph, or document it as unsupported and require an app-role mapping instead?
