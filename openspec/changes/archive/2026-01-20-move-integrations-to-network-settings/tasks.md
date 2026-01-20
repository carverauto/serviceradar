## 1. Navigation Updates
- [x] 1.1 Remove "Integrations" tab from `settings_tabs` in `settings_components.ex`
- [x] 1.2 Add "Integrations" tab to `network_tabs` in `settings_components.ex`
- [x] 1.3 Update `network_tabs` active state to include `/settings/networks/integrations` paths

## 2. Route Updates
- [x] 2.1 Remove integration routes from `/admin` scope in `router.ex`
- [x] 2.2 Add integration routes under `/settings/networks` scope in `router.ex`
- [x] 2.3 Verify route paths: `/settings/networks/integrations`, `/settings/networks/integrations/new`, `/settings/networks/integrations/:id`, `/settings/networks/integrations/:id/edit`

## 3. LiveView Module Relocation
- [x] 3.1 Move `admin/integration_live/index.ex` to `settings/integrations_live/index.ex`
- [x] 3.2 Update module name from `Admin.IntegrationLive.Index` to `Settings.IntegrationsLive.Index`
- [x] 3.3 Update LiveView to use `network_nav` component instead of settings-only layout
- [x] 3.4 Update any internal route references (`~p"/admin/integrations"` -> `~p"/settings/networks/integrations"`)

## 4. Validation
- [x] 4.1 Verify navigation works: Settings -> Network -> Integrations tab appears
- [x] 4.2 Verify all CRUD operations: list, create, view, edit integrations
- [x] 4.3 Verify active state highlighting in both top nav and sub-nav
- [x] 4.4 Run `mix compile` to catch any broken references
