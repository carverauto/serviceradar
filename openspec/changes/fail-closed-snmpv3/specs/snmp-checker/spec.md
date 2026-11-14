## ADDED Requirements

### Requirement: Unknown SNMPv3 Security Levels Refuse Instead of Downgrading

The system SHALL NOT compile, transmit, or poll with `noAuthNoPriv` (or its
proto equivalent) for a security level that is present but not one of
`no_auth_no_priv`, `auth_no_priv`, `auth_priv`. Resource writes keep
rejecting such values as validation errors; broker resolution SHALL refuse
them as resolution errors; every compile path SHALL skip the affected
device or target with a credential-refusal warning rather than emitting an
unauthenticated configuration. Absent levels keep today's inference from
passwords.

#### Scenario: Typo'd level refuses at compile time

- **GIVEN** a v3 credential whose security level is the string `"authPrv"`
- **AND** valid auth and privacy passwords
- **WHEN** the SNMP compiler builds the agent target
- **THEN** the device is skipped with a credential-refusal warning
- **AND** no target is emitted with `security_level noAuthNoPriv`

#### Scenario: Explicit garbage in a broker secret refuses

- **GIVEN** a broker secret payload with `"security_level": "super-safe"`
- **WHEN** the credential resolver builds the credential
- **THEN** resolution returns an error naming the unknown level
- **AND** no credential is produced by inferring from the passwords

#### Scenario: Absent level still infers

- **GIVEN** a broker secret payload with no `security_level` key but an
  `auth_password`
- **WHEN** the credential resolver builds the credential
- **THEN** the credential level is `auth_no_priv`

#### Scenario: Agent rejects UNSPECIFIED on the wire

- **GIVEN** an agent SNMP target whose proto security level is
  `SNMP_SECURITY_LEVEL_UNSPECIFIED`
- **WHEN** the agent applies the target
- **THEN** it returns an unknown-security-level error
- **AND** it does not poll with `NoAuthNoPriv`
