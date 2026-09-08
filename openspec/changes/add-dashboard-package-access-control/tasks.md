## 1. Catalog and Policy Editor vocabulary (Axis A)

- [ ] 1.1 Add explicit `section`, `resource`, and `action` fields to every entry in
      `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex`, with a compile-time
      assertion that no entry omits them.
- [ ] 1.2 Add an alias table to the catalog and teach `ServiceRadar.Identity.RBAC` (and
      `ServiceRadarWebNG.RBAC.can?/2` / `can_any?/2` / `permissions_for_scope/1`) to resolve aliases
      in both directions.
- [ ] 1.3 Declare `dashboards.packages.publish|enable|disable` as canonical, aliasing the existing
      `cli.dashboard.publish|enable|disable`. Leave `router.ex:191` and
      `dashboard_package_publish_controller.ex:67,129,177,341` untouched and prove they still pass.
- [ ] 1.4 Add `dashboards.packages.share` (operator default) and `dashboards.packages.view_all`
      (admin default) to the `dashboards` section.
- [ ] 1.5 Re-declare the five `analytics.dashboards.*` entries with `section: "dashboards"` and
      `resource: "dashboards.authored"`, keeping their keys and default roles unchanged.
- [ ] 1.6 Rewrite `build_permission_grid/1` and `build_section_resources/2` in
      `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live.ex` to build action rows per
      section from declared metadata; delete `split_permission_key/1` and `resource_short_label/2`.
- [ ] 1.7 Move `@action_order` out of the LiveView into the catalog module as a canonical vocabulary,
      and order out-of-vocabulary actions by section declaration order rather than a 999 sentinel.
- [ ] 1.8 Tests: Dashboards section renders exactly its own action rows; column headers are labels,
      not keys; an aliased pair renders one checkbox; a profile holding only the deprecated key
      passes a canonical-key check and vice versa.

## 2. Data model (Axis B)

- [ ] 2.1 Add `visibility` (`:private | :shared | :public`) and nullable `owner_id` to
      `ServiceRadar.Dashboards.DashboardInstance`, with `authorizers: [Ash.Policy.Authorizer]`.
- [ ] 2.2 Create `ServiceRadar.Dashboards.DashboardInstanceAccessGrant` mirroring
      `DashboardAccessGrant`'s subject vocabulary, with a NOT NULL FK to `dashboard_instances`,
      `ON DELETE CASCADE` on instance/user/group, `nilify` on `granted_by`, and the two partial
      unique identities.
- [ ] 2.3 Register the new resource on the `ServiceRadar.Dashboards` domain.
- [ ] 2.4 Extract the grant-matching expression shared by `ActorCanAccessDashboard`,
      `ActorCanAccessDashboardChild`, `ActorCanEditDashboard`, `ActorCanEditDashboardChild` and
      `ActorCanEditDashboardTarget` into one `Checks.SubjectGrant` module; rewrite those five modules
      to call it.
- [ ] 2.5 Add `ActorCanAccessDashboardInstance` (FilterCheck) and `ActorCanEditDashboardInstance` /
      `ActorCanEditDashboardInstanceTarget`, all built on `Checks.SubjectGrant`.
- [ ] 2.6 Add read/update/destroy policies to `DashboardInstance` and the new grant resource,
      including the `dashboards.packages.view_all` bypass and the owner-implicit share path.
- [ ] 2.7 Generate the migration with `mix ash.codegen add_dashboard_instance_access_control`, then
      hand-add the backfill and its verification query (see 5.1).
- [ ] 2.8 Tests: an equivalent grant on an authored dashboard and on an instance yields the same
      decision; group grants follow membership changes; grants cascade on instance delete.

## 3. Surface enforcement

- [ ] 3.1 `DashboardPackageLive.Show`: authorize in `handle_params/3` where the async load runs;
      render an indistinguishable not-found state; emit no stream token, manifest, data frames, or
      renderer reference when unauthorized.
- [ ] 3.2 `Packages.enabled_instances/1` and `get_enabled_instance_by_slug/2`: rely on the
      authorized read; add a regression test that a `scope:` argument now actually filters.
- [ ] 3.3 `DashboardHubLive.Index`: omit non-viewable instances entirely (no placeholder rows); send
      a user whose default dashboard became invisible to the hub with a notice.
- [ ] 3.4 `DashboardFrameChannel.stream_token/3`: add the minting user's id to the payload.
- [ ] 3.5 `DashboardFrameChannel.join/3`: verify token user against socket user, re-derive authority
      with `ServiceRadarWebNG.RBAC.authorize_current/2`, and re-check instance viewability.
- [ ] 3.6 `DashboardPackageAssetController.show/2`: serve only when the requester can view at least
      one enabled instance backed by the package; keep the existing enabled/verified checks; record
      an audit event that distinguishes forbidden from not-found.
- [ ] 3.7 Gate frame-query overrides (`show.ex` `frame_query_overrides/1` /
      `apply_frame_query_overrides/2`) on the viewer's analytics query permission; ignore overrides
      for a view-only grantee and keep them out of the signed token.
- [ ] 3.8 Record `owner_id` on instances created through the publish/enable API; leave it null for
      first-party seeding.
- [ ] 3.9 Tests per surface: cross-user token replay rejected; mid-session revocation rejected on
      rejoin; renderer withheld when no instance is viewable; renderer served when any instance is;
      hub omits restricted dashboards; route not-found is indistinguishable from unknown slug.

## 4. Sharing UI

- [ ] 4.1 Add a sharing control to the package dashboard surface for visibility and grants, reusing
      the authored share-principals picker and its `analytics.share_principals.view` gate.
- [ ] 4.2 Show the control to the instance owner and to `dashboards.packages.share` holders only.
- [ ] 4.3 Reconcile with `Admin.DashboardPackageLive.Index`, which currently gates on
      `plugins.view` / `plugins.stage` / `plugins.approve` -- decide and document which permission
      governs the settings surface after this change.
- [ ] 4.4 Tests: owner can share; viewer cannot; picker hidden without share-principals permission.

## 5. Rollout and migration

- [ ] 5.1 Migration backfills `visibility = 'public'` on all pre-existing `dashboard_instances` rows,
      leaves `owner_id` null, then asserts zero pre-existing rows remain non-public and raises if any
      do.
- [ ] 5.2 Add the `dashboards.packages.default_visibility` deployment setting with shipped value
      `public`; read it when creating an instance.
- [ ] 5.3 Generate a wholly synthetic pre-upgrade `dashboard_instances` fixture, migrate it through
      the guarded database lifecycle, and verify that every previously reachable synthetic route
      remains reachable post-migration.
- [ ] 5.4 CHANGELOG entry stating explicitly that this release changes no existing dashboard's
      audience, and that a future release will flip the shipped default.
- [ ] 5.5 Confirm rollback: revert the release on a staging deployment and re-check that dashboards
      are reachable with the new columns still present.

## 6. Verification

- [ ] 6.1 `bazel test -c opt --config=remote //... --test_tag_filters=-integration_test,-acceptance_test`.
- [ ] 6.2 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` and
      `--project elixir/serviceradar_core`.
- [ ] 6.3 Integration shard covering the new policies via the guarded SRQL-fixture lifecycle
      (`.agents/skills/srql-fixtures-db-tests/SKILL.md`), with `--nocache_test_results` and a
      `teardown_db` after a red shard.
- [ ] 6.4 Manual pass in the Docker Compose mTLS stack: two users, one restricted dashboard, checking
      route, hub, channel, and renderer for each.
- [ ] 6.5 `openspec validate add-dashboard-package-access-control --strict`.
