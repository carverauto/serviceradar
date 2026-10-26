## 1. Implementation
- [x] 1.1 Accept an AWX host's exact `ansible_host` address match when the first DNS labels of the host names agree, ignoring case.
- [x] 1.2 Claim the matched device as the host's own inventory record (`:host_inventory_record`) when no Proxmox guest anchors the AWX record and a MAC match or host-name agreement identifies the host, so an agent-managed device can be the survivor.
- [x] 1.3 Keep the address-only, host-name-only and MAC-contradiction refusals.
- [x] 1.4 Add database tests for the accepted cases and each refusal, failing before the change.
