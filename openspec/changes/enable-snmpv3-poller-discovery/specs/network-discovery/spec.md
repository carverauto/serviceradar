## MODIFIED Requirements

### Requirement: Discovery credential resolution via profiles
Mapper discovery MUST resolve SNMP credentials via SNMP profiles and per-device overrides using the shared credential resolution rules.

#### Scenario: Discovery uses profile credentials
- **GIVEN** a device matched by an SNMP profile target_query
- **WHEN** a mapper discovery job runs against that device
- **THEN** the job SHALL use the profile credentials for SNMP access

#### Scenario: Discovery uses device overrides
- **GIVEN** a device with a per-device SNMP credential override
- **WHEN** a mapper discovery job runs against that device
- **THEN** the device override SHALL take precedence over profile credentials

#### Scenario: Discovery uses SNMPv3 credential rules
- **GIVEN** an enabled credential rule for provider `snmp`, auth method `v3`, purpose `snmp_monitoring`
- **AND** the rule payload is SNMPv3 `authPriv` with username, auth protocol/password, and privacy protocol/password
- **WHEN** a mapper discovery job runs for an agent in the rule's edge scope
- **THEN** the compiled job credentials SHALL include `version` `v3`, `username`, `security_level`, auth fields, and privacy fields
- **AND** the mapper SHALL open a USM session with those credentials against seed targets
- **AND** the compiler MUST NOT require a profile `credential_secret_id` or a Kubernetes/Vault secret

## ADDED Requirements

### Requirement: Mapper SNMPv3 USM sessions
The mapper discovery engine MUST open SNMPv3 sessions with `UserSecurityModel` and message flags that match the credential's security level. It MUST NOT hard-code `AuthPriv`.

#### Scenario: Mapper authPriv session
- **GIVEN** scheduled-job credentials with `version` `v3` and `security_level` `authPriv`
- **WHEN** mapper constructs an SNMP client for a seed IP
- **THEN** `Version` is SNMPv3
- **AND** `SecurityModel` is UserSecurityModel
- **AND** `MsgFlags` is AuthPriv
- **AND** USM username, auth protocol/passphrase, and privacy protocol/passphrase are set from the credential

#### Scenario: Mapper does not force AuthPriv on authNoPriv
- **GIVEN** scheduled-job credentials with `version` `v3` and `security_level` `authNoPriv`
- **WHEN** mapper constructs an SNMP client
- **THEN** `MsgFlags` is AuthNoPriv
- **AND** VLAN community indexing remains disabled

#### Scenario: Mapper JSON snake_case credentials decode
- **GIVEN** mapper compiler output `{"version":"v3","username":"monitor","security_level":"authPriv","auth_protocol":"SHA256","auth_password":"x","privacy_protocol":"AES256","privacy_password":"y"}`
- **WHEN** the agent applies gateway mapper config
- **THEN** the scheduled job's `SNMPCredentials` carries those fields
- **AND** they are not dropped because the Go struct used exported names without json tags

### Requirement: Mapper SNMPv3 protocol identifier normalization
Mapper SNMPv3 protocol identifiers MUST accept compact, hyphenated, and case-insensitive forms, and unknown identifiers MUST fail client construction.

#### Scenario: Hyphenated identifier accepted
- **GIVEN** mapper credentials with `auth_protocol` `SHA-256` and `privacy_protocol` `AES-256`
- **WHEN** mapper constructs a v3 client
- **THEN** gosnmp uses SHA256 and AES256

#### Scenario: Unknown identifier fails closed
- **GIVEN** mapper credentials with `auth_protocol` `SHA1`
- **WHEN** mapper constructs a v3 client
- **THEN** client construction returns an error
- **AND** the target is recorded as a failed SNMP walk, not as an empty successful discovery

### Requirement: Mapper SNMPv3 discovery produces inventory evidence
When SNMPv3 credentials are valid, mapper discovery MUST produce the same classes of evidence it produces for SNMPv2c: device fingerprint, interfaces, and topology when the device exposes those MIBs.

#### Scenario: Successful v3 walk yields fingerprint
- **GIVEN** a reachable SNMPv3 `authPriv` device that answers `sysName` / `sysDescr` / `sysObjectID`
- **WHEN** mapper runs an SNMP discovery job using those credentials
- **THEN** the published device payload includes `snmp_fingerprint.system` values
- **AND** discovered interfaces are published when IF-MIB is available

#### Scenario: Wrong v3 password does not look like an empty network
- **GIVEN** a reachable SNMPv3 device
- **AND** mapper credentials have the wrong authentication password
- **WHEN** mapper runs discovery against that seed
- **THEN** the job records an authentication failure for that target
- **AND** it MUST NOT publish a successful empty device result for that seed
