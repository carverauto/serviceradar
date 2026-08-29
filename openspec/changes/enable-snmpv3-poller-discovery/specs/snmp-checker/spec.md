## MODIFIED Requirements

### Requirement: SNMP Target Configuration

Each SNMP profile MUST contain a list of SNMP targets (network devices) to poll, with support for SNMPv1, SNMPv2c, and SNMPv3 authentication.

#### Scenario: SNMPv2c target with community string
- **GIVEN** an SNMP target configured with version v2c
- **AND** community string "public"
- **WHEN** the agent polls the target
- **THEN** SNMP GET requests use the community string for authentication

#### Scenario: SNMPv3 target with auth and privacy
- **GIVEN** an SNMP target configured with version v3
- **AND** security level authPriv with SHA/AES
- **WHEN** the agent polls the target
- **THEN** SNMP requests are authenticated and encrypted

#### Scenario: SNMPv3 target with auth and no privacy
- **GIVEN** an SNMP target configured with version v3
- **AND** security level authNoPriv with SHA
- **WHEN** the agent polls the target
- **THEN** SNMP requests are authenticated
- **AND** the session MUST NOT require a privacy protocol or privacy password

#### Scenario: SNMPv3 target with no auth and no privacy
- **GIVEN** an SNMP target configured with version v3
- **AND** security level noAuthNoPriv
- **WHEN** the agent polls the target
- **THEN** SNMP requests use USM with the configured username
- **AND** the session MUST NOT require auth or privacy material

#### Scenario: Incomplete SNMPv3 authPriv is rejected
- **GIVEN** an SNMP target configured with version v3 and security level authPriv
- **AND** the privacy password is missing
- **WHEN** the compiler or poller validates the target
- **THEN** the target MUST NOT be polled
- **AND** the failure MUST be reported as invalid SNMPv3 configuration

#### Scenario: Target polling interval
- **GIVEN** an SNMP target with poll_interval 60 seconds
- **WHEN** the collector is running
- **THEN** OIDs are polled approximately every 60 seconds
- **AND** polling continues until the collector is stopped

## ADDED Requirements

### Requirement: SNMPv3 USM session setup
The embedded SNMP poller MUST open SNMPv3 sessions with `UserSecurityModel` and message flags that match the target's security level.

#### Scenario: authPriv sets AuthPriv flags
- **GIVEN** a poller target with `v3_auth.security_level` of `authPriv`
- **WHEN** the poller constructs the gosnmp client
- **THEN** `Version` is SNMPv3
- **AND** `SecurityModel` is UserSecurityModel
- **AND** `MsgFlags` is AuthPriv
- **AND** USM username, auth protocol/passphrase, and privacy protocol/passphrase are set

#### Scenario: authNoPriv does not send privacy
- **GIVEN** a poller target with `v3_auth.security_level` of `authNoPriv`
- **WHEN** the poller constructs the gosnmp client
- **THEN** `MsgFlags` is AuthNoPriv
- **AND** privacy protocol remains NoPriv

### Requirement: SNMPv3 protocol identifier normalization
SNMPv3 auth and privacy protocol identifiers MUST be accepted in compact, hyphenated, and case-insensitive forms, and unknown identifiers MUST be rejected.

#### Scenario: Hyphenated SHA-256 selects SHA256
- **GIVEN** a poller target whose `auth_protocol` is `SHA-256`
- **WHEN** the poller constructs the USM parameters
- **THEN** gosnmp AuthenticationProtocol is SHA256

#### Scenario: Compact AES256 selects AES256
- **GIVEN** a poller target whose `priv_protocol` is `AES256`
- **WHEN** the poller constructs the USM parameters
- **THEN** gosnmp PrivacyProtocol is AES256

#### Scenario: Unknown protocol is an error
- **GIVEN** a poller target whose `auth_protocol` is `SHA1`
- **WHEN** the poller constructs the USM parameters
- **THEN** client construction returns an error
- **AND** the session MUST NOT fall back to NoAuth or MD5

### Requirement: SNMPv3 credential compilation from unified secrets
A resolved SNMP credential that carries SNMPv3 user material MUST compile as version v3 even when the parent profile or record version is still v2c.

#### Scenario: v3 secret bound to a v2c profile still polls as v3
- **GIVEN** a default SNMP profile whose `version` is `v2c`
- **AND** a bound credential secret created with the native SNMP `v3` auth method (username + auth password)
- **WHEN** the SNMP compiler emits agent config
- **THEN** the target `version` is `v3`
- **AND** `v3_auth` contains the username, security level, and secrets
- **AND** the target is not skipped for a missing community string

#### Scenario: Missing security_level is inferred
- **GIVEN** a v3 credential secret with username, auth password, and privacy password and no `security_level` field
- **WHEN** the credential is resolved
- **THEN** `security_level` is `auth_priv`

### Requirement: SNMPv3 authentication failures are reported
The embedded SNMP poller MUST report SNMPv3 authentication and privacy failures as target-unavailable with an error that identifies USM failure, not as a generic timeout with no cause.

#### Scenario: Wrong auth password
- **GIVEN** a reachable SNMPv3 `authPriv` device
- **AND** the compiled target has the wrong authentication password
- **WHEN** the poller attempts a GET
- **THEN** the target status is `available: false`
- **AND** the error message indicates authentication failure
