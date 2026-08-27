# Change: Access control for CLI-published dashboard packages

## Why

**Package dashboards have no access control at all.** `/dashboards/:route_slug` lives in the
`:require_authenticated_user` live_session with `on_mount [{UserAuth, :require_authenticated}, ShellHook]`
(`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex:915-925`), and
`DashboardPackageLive.Show.mount/3` (`live/dashboard_package_live/show.ex:23-38`) performs no
authorization whatsoever. Any authenticated user can open any dashboard by slug. Every adjacent
surface has the same hole:

- **The hub.** `/dashboards` lists every enabled instance to everyone: `Packages.enabled_instances/1`
  (`lib/serviceradar_web_ng/dashboards/packages.ex:260-268`) runs an unfiltered read, called from
  `DashboardHubLive.Index` (`live/dashboard_hub_live/index.ex:341`).
- **The data channel.** `DashboardFrameChannel.join/3`
  (`lib/serviceradar_web_ng_web/channels/dashboard_frame_channel.ex:20-48`) requires only that the
  socket carries a `current_user` and a server-signed stream token. The token payload is
  `%{"route_slug", "data_frames", "active_frame_ids"}` (`:174-180`) -- it is **not bound to a user**,
  so a token minted for one viewer is replayable by any other authenticated viewer for its full
  3600 s lifetime (`:16`).
- **The renderer blob.** `GET /dashboard-packages/:id/renderer[.wasm]`
  (`controllers/dashboard_package_asset_controller.ex:10-23`, routed on `:browser_raw_auth`,
  `router.ex:893-900`) serves any enabled + verified renderer to any authenticated user, keyed only
  by package UUID.

**The sharing machinery already exists -- it was just never extended to packages.**
`ServiceRadar.Dashboards.DashboardAccessGrant`
(`elixir/serviceradar_core/lib/serviceradar/dashboards/dashboard_access_grant.ex`) ships today with
user *and* group subjects, a `[:view, :edit]` access enum, partial-unique upsert identities, and Ash
policies. Enforcement is four `Ash.Policy.FilterCheck` modules plus one `SimpleCheck` for creates
(`lib/serviceradar/dashboards/checks/`), reading a `visibility` enum (`:private | :shared | :public`,
default `:private`) that lives on `AuthoredDashboard`
(`lib/serviceradar/dashboards/authored_dashboard.ex:177`). All of it is welded to the SRQL dashboard
builder: the grant table's `dashboard_id` is a **NOT NULL** FK to `platform.authored_dashboards`
(`priv/repo/migrations/20260521232025_create_dashboard_access_groups.exs:86-98`), and neither
`DashboardPackage` nor `DashboardInstance` declares `authorizers:` at all
(`dashboard_package.ex:9-11`, `dashboard_instance.ex:6-8`) -- so passing `scope:` into their reads
filters nothing.

**The Policy Editor cannot express the missing rules, and mislabels the rules it does show.**
Correcting a common misreading of this code: the Dashboards section does **not** render empty. The
catalog's `dashboards` section (`identity/rbac/catalog.ex:830-857`) holds only
`cli.dashboard.publish`, `.enable`, `.disable`. The grid builds **one global action-row set from
every key in the whole catalog** (`live/settings/rbac_live.ex:851-856`) and then narrows only the
*columns* to the active section (`section_grid/2`, `rbac_live.ex:1147-1164`). `@action_order`
(`rbac_live.ex:22`) has 11 entries and only *sorts*; unmatched actions fall to index 999 and still
render (`action_sort_index/1`, `rbac_live.ex:913-917`). The catalog declares 127 keys, from which
the grid derives 44 distinct action rows -- 43 trailing segments plus one *empty-string* row produced
by three colon-separated keys (`visibility_profiles:read|write|delete`, `catalog.ex:526-538`) that
`split_permission_key/1` cannot parse at all. The Dashboards tab therefore renders **44 rows against
a single column**, of which 41 are blank and the 3 live checkboxes land at rows 40-42. That column's
header is the literal string `cli.dashboard`, because `resource_short_label/2`
(`rbac_live.ex:920-926`) strips the prefix `dashboards.`, which never matches `cli.dashboard.`.
Meanwhile the five `analytics.dashboards.*` keys (`catalog.ex:33-60`) render on the **Analytics**
tab. And the Settings -> Dashboard Packages LiveView gates on
`plugins.view` / `plugins.stage` / `plugins.approve`
(`live/admin/dashboard_package_live/index.ex:25-31`), not on `cli.dashboard.*` at all -- so the
Dashboards section governs one HTTP endpoint group while the equivalent UI is governed by a
different section entirely.

So there is no permission an admin can grant, and no grant they can create, that means "this team
may see the NOC dashboard and not the finance one."

## What Changes

### Axis A -- make the Dashboards section legible (catalog + grid)

- **Catalog entries gain explicit `section`, `resource`, and `action` metadata.** Stop inferring the
  grid's shape by dot-splitting the key (`split_permission_key/1`, `rbac_live.ex:899-910`). A key and
  its presentation become independent, which is what lets dashboard permissions share one tab
  without renaming a single key.
- **The Policy Editor renders one action-row set per section**, ordered by a canonical CRUD
  vocabulary first and the section's declaration order after, so a section's rows are exactly the
  actions that section can express.
- **All dashboard permissions move onto the Dashboards tab** as two resource columns --
  `dashboards.authored` (the existing `analytics.dashboards.*` keys, displayed there, keys unchanged)
  and `dashboards.packages`. This is a visible reorganization of the editor, not a semantic change.
- **New canonical `dashboards.packages.*` namespace with aliases, not renames.**
  `dashboards.packages.publish|enable|disable` become the canonical names for the existing
  `cli.dashboard.publish|enable|disable`. The resolver treats each pair as equivalent in both
  directions, so the five hardcoded call sites -- `router.ex:191` (`fallback_permission:`) and
  `dashboard_package_publish_controller.ex:67,129,177,341` -- keep working untouched and no role
  profile needs rewriting. Two genuinely new keys are added for this change:
  `dashboards.packages.share` (operator default) and `dashboards.packages.view_all` (admin default),
  mirroring `analytics.dashboards.share` / `.view_all`.

### Axis B -- enforce access on every package-dashboard surface

- **`DashboardInstance` becomes the access-control subject**, not `DashboardPackage`: the instance
  owns `route_slug`, `enabled`, `placement` and `is_default` (`dashboard_instance.ex:75-121`), one
  package can back several instances, and a package is re-published under new versions while the
  route persists. It gains `visibility` (`:private | :shared | :public`), `owner_id`, and
  `authorizers: [Ash.Policy.Authorizer]`.
- **New `ServiceRadar.Dashboards.DashboardInstanceAccessGrant`**, a sibling of the existing grant
  with the same subject vocabulary (user or group, `[:view, :edit]`) on its own table with a real
  NOT NULL FK to `dashboard_instances`. See `design.md` for why this beats making
  `DashboardAccessGrant` polymorphic.
- **One shared grant-matching expression.** The `subject_type == :user` / group-membership predicate
  that today appears verbatim in five check modules is extracted into a single module that both the
  authored and instance checks call, so the two paths cannot drift.
- **Four surfaces gated by the same Ash predicate**: the route (`show.ex` `handle_params/3`, where
  the load actually happens), the hub listing, `DashboardFrameChannel.join/3`, and the renderer blob
  controller. The channel additionally binds its stream token to the minting user and re-derives
  authority on join via `ServiceRadarWebNG.RBAC.authorize_current/2` (`lib/serviceradar_web_ng/rbac.ex:64-72`).
- **A `:view` grant does not confer SRQL query override.** `?q=` and `?frame_<id>=` params replace a
  manifest's declared frame query (`show.ex:528-545`, `565-578`) and are then signed into the stream
  token. Overriding remains gated on the viewer's own analytics query permission.
- **`DashboardPackage` stays unauthorized-by-resource** but its renderer blob is served only when the
  requester can view at least one instance backed by that package.

### Rollout -- what happens to existing dashboards (**required decision, not optional**)

Today every enabled instance is world-readable to every authenticated user. A default-deny rollout
would black out every existing viewer on upgrade, and `DashboardInstance` has no owner column, so a
default-private backfill would make existing dashboards visible to *nobody* except `view_all`
holders. Therefore:

- The migration backfills **`visibility = :public` on every existing `dashboard_instances` row** and
  adds `owner_id` as nullable, left NULL for pre-existing rows. Public + NULL owner reproduces
  today's behaviour exactly: **zero viewers lose access on upgrade.**
- **Newly created instances also default to `:public` for one release.** The default is read from a
  deployment setting `dashboards.packages.default_visibility` (shipped value `public`), so the model
  lands inert and a deployment can opt into `private` when it is ready.
- A later release flips the shipped default to `private`, announced in `CHANGELOG`. That is a
  separate, deliberate change -- not a side effect of this one.
- `dashboards.packages.view_all` (admin by default) always bypasses grants, so no admin can lock
  themselves out of a dashboard they own the deployment for.
- Grant and visibility mutations are recorded through AshPaperTrail (`ServiceRadar.Dashboards`
  already enables `paper_trail include_versions? true`, `dashboards.ex:19-21`), append-only, so a
  revoked-then-restored grant leaves a trace.

## Impact

- **Affected specs:** `dashboard-package-access-control` (new capability), `platform-security`
  (added -- permission catalog metadata and Policy Editor grid rendering).
- **Affected code:**
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/dashboard_instance.ex` (visibility, owner, policies)
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/dashboard_instance_access_grant.ex` (new)
  - `elixir/serviceradar_core/lib/serviceradar/dashboards/checks/` (shared subject-grant expression, new instance checks)
  - `elixir/serviceradar_core/lib/serviceradar/identity/rbac/catalog.ex` and the RBAC resolver (metadata, aliases, new keys)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/rbac_live.ex` (per-section action rows, metadata-driven labels)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_package_live/show.ex` (authorize in `handle_params/3`, user-bound stream token)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/dashboard_hub_live/index.ex` and `lib/serviceradar_web_ng/dashboards/packages.ex` (filtered listing)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/channels/dashboard_frame_channel.ex` (token binding, join authorization)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/dashboard_package_asset_controller.ex` (blob authorization)
  - one Ash migration under `elixir/serviceradar_core/priv/repo/migrations/`
- **Related in-flight changes:** `add-cli-dashboard-publish-api` owns the `cli.dashboard.*` keys and
  their `RBAC catalog additions` requirement; this change adds aliases rather than modifying that
  requirement, so the two can archive in either order. `add-dashboard-creator` owns the authored-side
  grant model this change deliberately does not disturb. `add-device-group-grants` establishes the
  per-resource grant-table pattern followed here.
- **Not breaking.** No permission key is removed or renamed, no existing viewer loses access, and the
  global-permission check remains the first `authorize_if` on every policy.
