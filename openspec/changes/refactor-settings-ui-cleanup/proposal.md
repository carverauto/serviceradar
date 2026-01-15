# Change: Settings UI Cleanup and Reorganization

## Why
The Settings UI has accumulated navigation bugs, broken forms, and structural inconsistencies that hinder usability. Multiple pages cause the topbar/sidebar to disappear, forms fail to capture input correctly, and the Edge Ops onboarding flow is confusing with redundant options. This proposal consolidates fixes from issue #2310 and related issues into a cohesive cleanup effort.

## What Changes

### Navigation & Layout Fixes
- Fix SNMP settings page causing topbar/sidebar to disappear
- Fix Sysmon settings page causing topbar/sidebar to disappear

### Settings Structure Reorganization
- Rename "Networks" tab to "Network" in Settings
- Move SNMP settings under the "Network" tab (instead of top-level)
- Create new "Agents" section in Settings
- Move "Sysmon" under the new "Agents" section
- Add "Deploy New Agent" button in the Agents section

### SNMP Improvements
- Add SNMP credentials forms (community strings, SNMPv3 auth)
- Currently missing any way to input SNMP authentication

### Edge Ops Simplification
- Consolidate Edge Ops to have exactly two onboarding flows:
  1. Agent onboarding (for deploying new agents)
  2. NATS leaf server onboarding (for edge connectivity)
- Remove redundant/confusing onboarding options
- Edge Ops in Settings should have a single clear button for NATS leaf server setup

### Form Bug Fixes
- Fix Sysmon profile form: selecting "Processes" breaks form validation (mount points error)
- Fix Network sweep profile creator: ports field doesn't register comma-separated input
- Fix Integration source forms: show dynamic fields based on source type (Armis, Netbox, etc.)

### Device UI Enhancements
- Show total device count in pagination (e.g., "20 / 1,234")
- Add improved pagination controls (page numbers, not just arrows)
- Add "Add Device" button to devices view
- Add "Import Devices" button with CSV/spreadsheet support
- Add "Device Discovery" button linking to discovery settings
- Enable device detail editing with RBAC protection (Edit button)

### Integration Source Cleanup
- Dynamic form fields based on integration type
- Proper credential forms for Armis API, Netbox API
- Network blacklist only shows for integrations that support it
- Remove "nmap" as integration source (replace with native discovery)

## Impact
- Affected specs: `build-web-ui`
- Affected code: `web-ng/lib/service_radar_web/live/settings/`, device views, integration forms
- Related issues: #2310, #2289, #2292, #2293, #2254, #2269, #2265, #2262, #2259

## Out of Scope
- RBAC builder/editor (#2293) - separate proposal due to complexity
- SRQL search filter fixes (#2254) - tracked in existing `fix-services-page-srql` change

## Status: Nearly Complete

### Completed
- Navigation & Layout Fixes (SNMP, Sysmon pages) ✅
- Settings Structure Reorganization (Network/Agents tabs, sub-nav) ✅
- SNMP Credentials (already existed in SNMPTarget resource) ✅
- Edge Ops Simplification (renamed tabs, improved Deploy page) ✅
- Form Bug Fixes (array field transforms for Sysmon, Networks) ✅
- Integration Source Forms (dynamic fields for Armis, SNMP, Netbox) ✅
- Device UI pagination total count ✅
- Device UI action buttons and modals ✅
- Device edit with RBAC protection (#2292) ✅
- Netbox API credentials form fields ✅
- CSV import with LiveView uploads and preview ✅

### Remaining (Nice-to-have)
- Page number pagination controls
- Network blacklist field conditional display
- Remove/deprecate nmap integration source

### Closed Issues
- #2289 - sysmon settings ui broken
- #2269 - show total device count
- #2262 - network sweep profile broken
- #2259 - integration source cleanup
- #2292 - device edit UI
