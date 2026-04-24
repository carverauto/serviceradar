## 1. Implementation
- [x] 1.1 Add a platform-schema `ocsf_events` hypertable migration with indexes aligned to the OCSF Event Log Activity schema.
- [x] 1.2 Implement a core-elx log promotion consumer that subscribes to processed log subjects and invokes `LogPromotion.promote/1` without inserting logs.
- [x] 1.3 Wire configuration + supervision for the promotion consumer and surface health/telemetry for visibility.
- [x] 1.4 Add tests covering rule match promotion from processed logs into `ocsf_events`.
- [x] 1.5 Update demo/helm configuration to enable the promotion consumer.
- [ ] 1.6 Manual verification: create a log rule, ingest matching logs, and confirm new `ocsf_events` rows appear and the Events UI updates.
