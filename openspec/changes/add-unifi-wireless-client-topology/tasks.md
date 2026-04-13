## 1. Specification
- [x] 1.1 Confirm the controller payload(s) used for UniFi wireless client association data
- [x] 1.2 Validate this change with `openspec validate add-unifi-wireless-client-topology --strict`

## 2. Mapper
- [x] 2.1 Extend the UniFi poller to extract wireless client associations from controller responses
- [x] 2.2 Publish AP-to-client topology links with endpoint-attachment semantics and stable metadata
- [x] 2.3 Preserve existing LLDP/port/uplink extraction behavior

## 3. Verification
- [x] 3.1 Add focused tests for UniFi wireless client topology extraction
- [ ] 3.2 Validate that AP-associated clients reach mapper topology output without being mislabeled as backbone links
