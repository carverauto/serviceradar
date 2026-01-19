# Change: Remove Interfaces Navigation and Add Device Interfaces Tab

## Why
The current Interfaces page as a standalone navigation item duplicates information that belongs contextually within the Device Details view. Users need to see interfaces in the context of a specific device, not as a separate global list. This change improves UX by consolidating interface information where it's most relevant.

## What Changes
- **REMOVED**: Interfaces sidebar navigation link (`/interfaces` route)
- **REMOVED**: InterfaceLive.Index page (`web-ng/lib/serviceradar_web_ng_web/live/interface_live/index.ex`)
- **REMOVED**: Router entry for `/interfaces`
- **ADDED**: New "Interfaces" tab in Device Details page (alongside existing "Details" and "Profiles" tabs)
- **MODIFIED**: Device Details tab structure to support `Details | Interfaces | Profiles` layout
- Tab visibility: "Interfaces" tab shown only when device has discovered interfaces

## Impact
- Affected specs: `device-inventory` (UI presentation of network_interfaces)
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/components/layouts.ex` (remove nav link)
  - `web-ng/lib/serviceradar_web_ng_web/router.ex` (remove route)
  - `web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex` (add Interfaces tab)
  - `web-ng/lib/serviceradar_web_ng_web/live/interface_live/index.ex` (remove)

## Notes
- The existing `network_interfaces_card` component (currently in Details tab showing max 10 interfaces) will be replaced with a full interfaces tab that shows all interfaces
- No data model changes required - `network_interfaces` JSONB array already exists in device records
