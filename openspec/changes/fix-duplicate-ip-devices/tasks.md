## 1. Implementation
- [ ] 1.1 Audit DIRE IP-only resolution paths (sweep, mapper, sync) and identify where duplicate device IDs are created.
- [ ] 1.2 Add partition + primary IP lookup for IP-only updates before generating a new device ID.
- [ ] 1.3 Extend reconciliation to merge devices sharing the same partition + primary IP.
- [ ] 1.4 Emit metrics/logs for IP-only resolution and merge outcomes.
- [ ] 1.5 Add tests for IP-only de-duplication and reconciliation merge behavior.
