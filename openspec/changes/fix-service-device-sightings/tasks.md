## 1. Investigation and plan
- [ ] 1.1 Capture current poller/agent status payloads and registry behavior with identity reconciliation enabled to confirm sighting demotion and missing IP/hostname.
- [ ] 1.2 Decide partition and identity strategy for service devices (host device vs ServiceRadar IDs) and expected visibility in the default partition.

## 2. Fixes
- [ ] 2.1 Update the registry so ServiceRadar service updates and self-reported host registrations bypass sighting ingest and stay as authoritative devices; add unit tests.
- [ ] 2.2 Harden poller/agent source IP + hostname resolution (use concrete IPv4/pod IP, normalize, propagate) so device updates carry real identity data; add tests.
- [ ] 2.3 Align partition metadata for service components so they appear in the default partition without creating duplicate IDs; add regression coverage.

## 3. Validation
- [ ] 3.1 Add/refresh tests covering poller/agent → registry identity flow under identity reconciliation (no service sightings, IP/hostname present).
- [ ] 3.2 Run `openspec validate fix-service-device-sightings --strict` and address any spec lint issues.
