## 1. Implementation

- [x] 1.1 Add `/interfaces` route to Phoenix router in the authenticated live_session
- [x] 1.2 Create `InterfaceLive.Index` LiveView module with SRQL query support
- [x] 1.3 Create interface list table component showing MAC, IP addresses, device, status
- [x] 1.4 Add click-through navigation from interface row to existing InterfaceLive.Show
- [x] 1.5 Support all SRQL filter fields defined in catalog (mac, if_name, if_index, etc.)

## 2. Testing

- [ ] 2.1 Verify `/interfaces` route loads without 404
- [ ] 2.2 Test MAC address search: `in:interfaces mac:0c:ea:14:32:d2:80`
- [ ] 2.3 Test other filter fields (if_name, device_id, admin_status, oper_status)
- [ ] 2.4 Verify pagination and sorting work correctly
- [ ] 2.5 Verify click-through to interface details page works
