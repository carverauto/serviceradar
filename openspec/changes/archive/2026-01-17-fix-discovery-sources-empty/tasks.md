## 1. Implementation

- [x] 1.1 Update `normalize_update/1` in sync_ingestor.ex to extract `source` field from incoming update payloads
- [x] 1.2 Update `build_device_upsert_records/2` to include `discovery_sources` as a single-element array containing the source
- [x] 1.3 Update `bulk_upsert_devices/2` to merge discovery_sources on conflict using array concatenation with deduplication
- [x] 1.4 Add unit tests for source extraction and propagation through the ingestor pipeline
- [x] 1.5 Verify fix with integration test using armis/netbox mock data
