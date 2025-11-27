## 1. Investigation and plan
- [x] 1.1 Capture current poller/agent status payloads and registry behavior with identity reconciliation enabled to confirm sighting demotion and missing IP/hostname. (Covered via registry/poller unit tests asserting service updates bypass sightings and IPs/hostnames get resolved.)
- [x] 1.2 Decide partition and identity strategy for service devices (host device vs ServiceRadar IDs) and expected visibility in the default partition. (Decision: keep `serviceradar:` device IDs but explicitly place service devices in the `default` partition field; fall back to stored poller status for missing IPs.)

## 2. Fixes
- [x] 2.1 Update the registry so ServiceRadar service updates and self-reported host registrations bypass sighting ingest and stay as authoritative devices; add unit tests.
- [x] 2.2 Harden poller/agent source IP + hostname resolution (use concrete IPv4/pod IP, normalize, propagate) so device updates carry real identity data; add tests.
- [x] 2.3 Align partition metadata for service components so they appear in the default partition without creating duplicate IDs; add regression coverage.

## 3. Validation
- [x] 3.1 Add/refresh tests covering poller/agent → registry identity flow under identity reconciliation (no service sightings, IP/hostname present).
- [x] 3.2 Run `openspec validate fix-service-device-sightings --strict` and address any spec lint issues.

## 4. Deployment and verification (in progress)
- [ ] 4.1 Deploy latest ICMP/poller/agent identity fixes to demo with images built from `32db2915ca79741bf551ad8af98d1ce359ce46f8` (core `sha-88d3a8af915b...`, web `sha-ea0415aa1069...`, poller `sha-bccc4567ef2a...`, agent `sha-9c92617fce5f...`, datasvc `sha-bdc0057ce88c...`, sync `sha-022d570f8aeb...`, snmp-checker `sha-b32c3d1c9923...`, srql `sha-1a10f7b7285...`, tools `sha-36d2645dd65...`).
- [ ] 4.2 Verify in demo UI/inventory that ICMP capability is attached only to the agent device (no poller ICMP sparkline) and that the poller is marked available when reporting.
- [ ] 4.3 Resolve Helm pre-upgrade hook failure: `serviceradar-secret-generator` job currently `ImagePullBackOff` in `demo`, leaving the last upgrade partially applied and pods still on prior (8h-old) images.
