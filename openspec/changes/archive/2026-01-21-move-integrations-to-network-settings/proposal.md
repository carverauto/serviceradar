# Change: Move Integrations to Network Settings

## Why
The Integrations configuration page is currently a top-level tab in Settings (`/admin/integrations`), but it logically belongs under the Network section. Integration sources (Armis, SNMP, Netbox, etc.) are discovery mechanisms that feed into the network/device pipeline. Moving Integrations under Settings -> Network -> Integrations improves information architecture and aligns with the existing Network sub-navigation pattern (Sweep Profiles, Discovery, SNMP).

## What Changes
- Remove "Integrations" from top-level Settings tabs
- Add "Integrations" as a sub-tab under the Network section (alongside Sweep Profiles, Discovery, SNMP)
- Move routes from `/admin/integrations/*` to `/settings/networks/integrations/*`
- Move LiveView module from `admin/integration_live/` to `settings/integrations_live/`
- Update IntegrationLive to use `network_nav` sub-navigation component

## Impact
- Affected specs: `build-web-ui`
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/router.ex` - route changes
  - `web-ng/lib/serviceradar_web_ng_web/components/settings_components.ex` - nav updates
  - `web-ng/lib/serviceradar_web_ng_web/live/admin/integration_live/` - move to settings/
- Related issues: #2375
