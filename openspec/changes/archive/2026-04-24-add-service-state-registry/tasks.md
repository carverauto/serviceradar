## 1. Implementation
- [x] 1.1 Add a `ServiceState` Ash resource + migration (platform schema).
- [x] 1.2 Upsert `ServiceState` from service-status ingestion (gateway + plugin results).
- [x] 1.3 Add revoke/delete hooks to update or remove `ServiceState` for plugin services.
- [x] 1.4 Add PubSub broadcast for service-state changes and update LiveView to refresh on it.
- [x] 1.5 Update Services dashboard summary to query `service_state` for current counts.
- [ ] 1.6 (Optional) Add staleness classification or TTL policy for non-reporting services.
- [ ] 1.7 Tests for service-state upsert + revoke/delete behavior.
