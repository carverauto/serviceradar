# Change: Give Inventory Cleanup its own Settings page and keep every Settings page searchable

## Why

The Inventory Cleanup settings (ephemeral device expiry, source id retirement and its
mass-change guard override, purge of soft-deleted devices) were a tab of Sweep Profiles,
which has nothing to do with them, and the Settings search could not reach them by the
names of their own settings. Nothing stopped the next Settings page or tab from being
added without a catalog entry, which is the only way search reaches a page.

## What Changes

- Inventory Cleanup becomes its own page at `/settings/networks/inventory-cleanup`, listed
  under Network Services > Discovery, with the same form, settings resource and
  `settings.networks.manage` permission. Sweep Profiles drops the tab.
- `/settings/networks?tab=cleanup` redirects to the new page.
- Every in-page tab a Settings LiveView handles has a catalog sub-entry (Rules, Integrations
  and Notifications tabs were missing), and a catalog test reads the router so that a new
  Settings route or tab without a catalog entry, or a catalog link without a route, fails CI.
- The sidebar view filter matches every typed word in any order, as the Ctrl+K palette
  already does, and both searches include the page description.

## Impact

- Affected specs: build-web-ui
- Affected code: `elixir/web-ng` Settings catalog, shell search, `NetworksLive.Index`,
  new `Settings.InventoryCleanupLive`
