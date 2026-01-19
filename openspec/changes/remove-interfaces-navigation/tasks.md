## 1. Remove Interfaces Navigation

- [x] 1.1 Remove Interfaces sidebar link from `layouts.ex` (lines ~160-167)
- [x] 1.2 Remove `section_label("interfaces")` helper function
- [x] 1.3 Remove `section_icon("interfaces")` helper function

## 2. Remove Interfaces Route and Page

- [x] 2.1 Remove `/interfaces` route from `router.ex`
- [x] 2.2 Delete `interface_live/index.ex` file
- [x] 2.3 Remove any related interface live components if orphaned

## 3. Add Interfaces Tab to Device Details

- [x] 3.1 Modify Device Details tab structure to include "Interfaces" tab
- [x] 3.2 Add conditional rendering - show Interfaces tab only when device has network_interfaces
- [x] 3.3 Create interfaces tab content component with full interfaces table
- [x] 3.4 Remove embedded `network_interfaces_card` from Details tab (avoid duplication)

## 4. Interfaces Tab UI

- [x] 4.1 Display all interfaces (remove 10-item limit from current card)
- [x] 4.2 Show columns: Name, IP, MAC, Type
- [x] 4.3 Add scrollable container for devices with many interfaces

## 5. Testing and Verification

- [x] 5.1 Verify Interfaces nav link is removed from sidebar
- [x] 5.2 Verify `/interfaces` route removed from router
- [x] 5.3 Test device details page shows Interfaces tab when interfaces exist
- [x] 5.4 Test device details page hides Interfaces tab when no interfaces
- [x] 5.5 Verify all interfaces are displayed (not truncated)
