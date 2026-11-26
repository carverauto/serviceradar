# Tasks: media digest feed, record relay, and device access for native add-ons

## 1. Protocol and SDKs
- [ ] 1.1 `addon.proto`: `StreamMediaDigests` (MediaDigestFrame/Ack with gap and session entries) and `RelayRecords` (AddonRecordFrame/RecordRelayAck)
- [ ] 1.2 Go SDK (`go/pkg/addon`) and Rust add-on SDK helpers for both capabilities; reference add-on tests

## 2. Agent
- [ ] 2.1 `sr-au-v1` digest hook in the shared relay uploader, active only while a subscriber exists; golden vectors
- [ ] 2.2 Digest feed pump: per-add-on bound, gap entries, session entries, never blocking relaying
- [ ] 2.3 Record relay pump into the edge spool, with cumulative acks (following the `otlp-relay` pump)
- [ ] 2.4 Manifest `devices` field with allowlist (`/dev/tpmrm0`, PC/SC); systemd `DeviceAllow=` and supplementary groups; refuse disallowed devices

## 3. Core and Helm
- [ ] 3.1 Edge contract catalog entry `serviceradar.addon.record` v1, and a projector publishing to `addons.records.<addon_id>.v1` with headers and `Nats-Msg-Id`
- [ ] 3.2 Core-owned `ADDON_RECORDS` stream; sizing in the render-time budget
- [ ] 3.3 `addonRecords.consumers` grants; extend `nats_static_user_permissions_test`

## 4. Validation
- [ ] 4.1 Tests: digest vectors, feed overflow gaps, relay unaffected under a stalled add-on, record relay through an outage, byte-identical publication, device allowlist
- [ ] 4.2 `openspec validate add-addon-media-digest-and-record-relay --strict`
