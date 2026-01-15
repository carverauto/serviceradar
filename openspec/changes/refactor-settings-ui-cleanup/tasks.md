# Tasks: Settings UI Cleanup

## 1. Navigation & Layout Fixes
- [x] 1.1 Fix SNMP settings page layout (restore topbar/sidebar)
- [x] 1.2 Fix Sysmon settings page layout (restore topbar/sidebar)
- [ ] 1.3 Audit other settings pages for layout consistency

## 2. Settings Structure Reorganization
- [x] 2.1 Rename "Networks" tab to "Network" in sidebar
- [x] 2.2 Create new "Agents" section in Settings sidebar
- [x] 2.3 Move Sysmon under Agents section (with sub-nav)
- [x] 2.4 Move SNMP settings under Network tab (with sub-nav)
- [x] 2.5 Add "Deploy New Agent" button/action in Agents section
- [x] 2.6 Update Settings router/navigation for new structure

## 3. SNMP Credentials Forms
- [x] 3.1 Design SNMP credentials form (community strings, SNMPv3) - Already exists in SNMPTarget
- [x] 3.2 Implement SNMP credentials LiveView component - Already exists in SNMPTarget
- [x] 3.3 Add backend support for storing SNMP credentials - Already exists in SNMPTarget
- [x] 3.4 Wire credentials to SNMP checker configuration - Already exists in SNMPTarget

## 4. Edge Ops Simplification
- [x] 4.1 Audit current Edge Ops onboarding flows
- [x] 4.2 Renamed tabs: "Edge Sites", "Data Collectors", "Components"
- [x] 4.3 Ensure agent onboarding is in Agents section (not Edge Ops)
- [x] 4.4 Updated Deploy Agent page with clearer guidance
- [x] 4.5 Update Edge Ops documentation/help text

## 5. Form Bug Fixes
- [x] 5.1 Fix Sysmon profile form: disk_paths/disk_exclude_paths array handling
- [x] 5.2 Fix Network sweep profile: ports field input handling
- [ ] 5.3 Audit other forms for similar input handling issues

## 6. Integration Source Forms
- [x] 6.1 Implement dynamic form fields based on source type
- [x] 6.2 Add Armis API credentials form fields (api_key, api_secret)
- [x] 6.3 Add SNMP credentials form fields (version, community)
- [x] 6.4 Add Netbox API credentials form fields (url, token, verify_ssl)
- [ ] 6.5 Conditionally show network blacklist field
- [ ] 6.6 Remove/deprecate nmap integration source option

## 7. Device UI Enhancements
- [x] 7.1 Add total count to pagination display
- [ ] 7.2 Implement improved pagination controls (page numbers)
- [x] 7.3 Add "Add Device" button to devices view
- [x] 7.4 Create "Add Device" modal/form
- [x] 7.5 Add "Import Devices" button
- [x] 7.6 Create CSV import modal with template download
- [x] 7.7 Implement CSV parsing with LiveView uploads and preview
- [x] 7.8 Add "Device Discovery" button linking to Network settings
- [x] 7.9 Add Edit button to device details (RBAC protected)
- [x] 7.10 Implement editable device details form with phx-debounce

## 8. Testing & Validation
- [x] 8.1 Compile check - all files compile without errors
- [ ] 8.2 Test all settings pages for layout consistency
- [ ] 8.3 Test all forms for input handling
- [ ] 8.4 Test device CRUD operations
- [ ] 8.5 Test CSV import with various file formats
- [ ] 8.6 Verify RBAC enforcement on edit actions

## Related Issues
- [x] #2289 - bug: sysmon settings ui is broken (Fixed: added Layouts.app wrapper)
- [x] #2292 - Update Device Details UI to allow Edits (Fixed: Edit button with RBAC, editable form with phx-debounce)
- [ ] #2293 - feat: RBAC builder/editor (out of scope)
- [ ] #2254 - bug(srql): search filters broken in UI (separate issue)
- [x] #2269 - feat(ui): show total device count in device UI (Fixed: added total_count to pagination)
- [x] #2265 - feat: add devices from UI (Partial: modal created, creation not implemented)
- [x] #2262 - bug: network sweep profile creator is broken (Fixed: added transform_profile_params)
- [x] #2259 - bug(ui): settings/integration source cleanup (Fixed: dynamic credential forms)
