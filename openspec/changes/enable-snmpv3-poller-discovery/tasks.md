## 1. Credential compilation

- [ ] 1.1 Add `security_level` (required for `authPriv`/`authNoPriv`) to the native SNMP v3 descriptor in `NativeDescriptors`, keeping field ids compatible with `broker_json_credential/3`
- [ ] 1.2 Infer `version: v3` from a v3 secret payload (username or auth/priv material present) even when the parent profile/record is still v2c
- [ ] 1.3 Infer `security_level` when omitted: priv password → `authPriv`, auth password only → `authNoPriv`, username only → `noAuthNoPriv`
- [ ] 1.4 Include `security_level` in `CredentialResolver.to_mapper_credentials/1`
- [ ] 1.5 Reject incomplete v3 material at compile time (`authPriv` missing priv, `authNoPriv` missing auth) instead of emitting a target the agent cannot open
- [ ] 1.6 Extend credential builder / resolver tests for v3 inference, explicit security level, and the skip-because-still-v2c bug

## 2. Mapper USM client

- [ ] 2.1 Add `SecurityLevel` to mapper `SNMPCredentials` / `SNMPCredentialConfig` / `mapperCredSpec` and parse it from scheduled-job JSON
- [ ] 2.2 Set `gosnmp.UserSecurityModel` on v3 sessions
- [ ] 2.3 Set `MsgFlags` from security level (`noAuthNoPriv` / `authNoPriv` / `authPriv`); stop hard-coding `AuthPriv`
- [ ] 2.4 Normalize auth/privacy protocol identifiers (compact, hyphenated, case-insensitive) and return an error on unknown values
- [ ] 2.5 Add `security_level` to `proto/discovery/discovery.proto` `SNMPCredentials`, regenerate stubs, and map it in `protoToSNMPCredentials`
- [ ] 2.6 Leave VLAN community indexing disabled for v3 credentials (existing gate)

## 3. Poller USM client

- [ ] 3.1 Normalize hyphenated and compact protocol identifiers when applying proto *and* when unmarshalling cached/local JSON
- [ ] 3.2 Treat unspecified auth/priv protocol as an error for the matching security level rather than defaulting to MD5/DES
- [ ] 3.3 Keep proto enum mapping (`SNMPProtoMapper` + `protoToSNMPAuthProtocol`) as the primary GetConfig path; JSON is the cache/local fallback

## 4. Failure reporting

- [ ] 4.1 Surface SNMPv3 authentication/privacy failures on mapper targets as explicit errors (not a silent empty walk)
- [ ] 4.2 Surface the same class of failure on poller target status (`available: false` + auth error text)
- [ ] 4.3 Do not skip a compiled v3 target because the parent profile version field is still v2c

## 5. Tests

- [ ] 5.1 Hermetic in-process SNMPv3 USM GET for `authPriv` (SHA + AES) against a local test agent, covering mapper client setup
- [ ] 5.2 Same for `authNoPriv` and `noAuthNoPriv`
- [ ] 5.3 Hermetic poller GET for `authPriv` with hyphenated (`SHA-256` / `AES-256`) identifiers
- [ ] 5.4 Compiler tests: v3 secret + v2c profile record still emits `version=v3` and `v3_auth` / mapper credentials
- [ ] 5.5 Mapper JSON decode test: snake_case credentials including `security_level` round-trip into `SNMPCredentials`
- [ ] 5.6 Proto mapping test for discovery `security_level`

## 6. Farm01 verification (after operator converts devices)

- [ ] 6.1 Confirm farm01 USM user, security level, and protocols with the operator
- [ ] 6.2 Roll farm01 onto the build *before* converting devices; v2c discovery/polling still succeed
- [ ] 6.3 After the v3 cutover, confirm a known switch answers mapper discovery (fingerprint + interfaces)
- [ ] 6.4 Confirm topology/LLDP or FDB evidence still appears for that switch
- [ ] 6.5 Confirm the SNMP poller writes interface metrics for that switch after config push
- [ ] 6.6 Confirm a wrong password produces an auth error in agent/mapper logs, not an empty success
