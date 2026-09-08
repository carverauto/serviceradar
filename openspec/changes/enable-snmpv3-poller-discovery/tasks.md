## 1. Credential rules

- [x] 1.1 Set `NativeDescriptors.snmp()["supports_rules"]` to `true` so SNMP appears on New Rule
- [x] 1.2 Add `security_level` to the native SNMP v3 descriptor (plus keep username / auth / priv fields). Do not default blank protocols to MD5/DES
- [x] 1.3 Resolve poller and mapper SNMP credentials from `NetworkCredentialRule` (provider `snmp`, purpose `snmp_monitoring`) for the compiling agent; a matching rule MUST win over profile `credential_secret_id`
- [x] 1.4 Infer `version: v3` from a v3 rule payload even when the parent profile row is still v2c
- [x] 1.5 If `priv_protocol` is set and `priv_password` is blank, reuse `auth_password` (UniFi single-password authPriv)
- [x] 1.6 Include `security_level` in `CredentialResolver.to_mapper_credentials/1`
- [x] 1.7 Reject incomplete v3 material at compile time (`authPriv` missing priv after inference, `authNoPriv` missing auth)
- [x] 1.8 Tests: rule resolution, rule-beats-profile-secret, UniFi password copy, SHA/AES authPriv compile, no MD5/DES default

## 2. Mapper USM client

- [x] 2.1 Add `SecurityLevel` to mapper `SNMPCredentials` / `SNMPCredentialConfig` / `mapperCredSpec` and parse it from scheduled-job JSON
- [x] 2.2 Set `gosnmp.UserSecurityModel` on v3 sessions
- [x] 2.3 Set `MsgFlags` from security level (`noAuthNoPriv` / `authNoPriv` / `authPriv`); stop hard-coding `AuthPriv`
- [x] 2.4 Normalize auth/privacy protocol identifiers (compact, hyphenated, case-insensitive) and return an error on unknown values
- [x] 2.5 Add `security_level` to `proto/discovery/discovery.proto` `SNMPCredentials`, regenerate stubs, and map it in `protoToSNMPCredentials`
- [x] 2.6 Leave VLAN community indexing disabled for v3 credentials (existing gate)

## 3. Poller USM client

- [x] 3.1 Normalize hyphenated and compact protocol identifiers when applying proto *and* when unmarshalling cached/local JSON
- [x] 3.2 Treat unspecified auth/priv protocol as an error for the matching security level rather than defaulting to MD5/DES
- [x] 3.3 Keep proto enum mapping (`SNMPProtoMapper` + `protoToSNMPAuthProtocol`) as the primary GetConfig path; JSON is the cache/local fallback

## 4. Failure reporting

- [x] 4.1 Surface SNMPv3 authentication/privacy failures on mapper targets as explicit errors (not a silent empty walk)
- [x] 4.2 Surface the same class of failure on poller target status (`available: false` + auth error text)
- [x] 4.3 Do not skip a compiled v3 target because the parent profile version field is still v2c
- [x] 4.4 Do not compile poller targets from stale v2c `snmp_targets` rows when a v3 credential rule matches the device

## 5. Tests

- [x] 5.1 Hermetic in-process SNMPv3 USM GET for `authPriv` (SHA + AES) against a local test agent, covering mapper client setup
- [x] 5.2 Same for `authNoPriv` and `noAuthNoPriv`
- [x] 5.3 Hermetic poller GET for `authPriv` with hyphenated (`SHA-256` / `AES-256`) identifiers
- [x] 5.4 Compiler tests: v3 credential rule + v2c profile record still emits `version=v3` and `v3_auth` / mapper credentials
- [x] 5.5 Mapper JSON decode test: snake_case credentials including `security_level` round-trip into `SNMPCredentials`
- [x] 5.6 Proto mapping test for discovery `security_level`

## 6. Farm01 verification

- [ ] 6.1 Create an SNMP credential **rule** (not a profile-bound secret): v3, SHA, AES, authPriv, UniFi password in both fields, scoped to the k8s agent
- [ ] 6.2 Roll farm01 onto the build; UniFi still has v2c enabled so mixed estate stays reachable
- [ ] 6.3 Poll the UDM at `192.168.2.1`, not `192.168.1.1`
- [ ] 6.4 Confirm a known switch (e.g. USW Pro 24) answers mapper discovery (fingerprint + interfaces)
- [ ] 6.5 Confirm topology/LLDP or FDB evidence still appears for that switch
- [ ] 6.6 Confirm the SNMP poller writes interface metrics after config push
- [ ] 6.7 Confirm a wrong password produces an auth error in agent/mapper logs, not an empty success
- [ ] 6.8 Confirm `last_run_interface_count` is not trusted: query `discovered_interfaces.timestamp` after the run
