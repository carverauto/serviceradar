# Credential Management

## ADDED Requirements

### Requirement: The TLS policy control is available whenever transport is configurable
The credential rule form SHALL render a TLS policy control whenever the provider
declares transport rule controls. When the selected auth method does not narrow
the permitted policies, the form SHALL offer the full policy set, matching the
backend rule that an undeclared list permits any policy.

#### Scenario: Provider declares transport but no policy list
- **GIVEN** a provider whose `rule_controls.transport` is true
- **AND** whose selected auth method declares no `tls_policies`
- **WHEN** an operator opens the credential rule form
- **THEN** the TLS policy control SHALL be rendered with both `verify` and `skip_verify`
- **AND** saving the rule SHALL succeed

#### Scenario: Auth method narrows the permitted policies
- **GIVEN** an auth method declaring `tls_policies: ["verify"]`
- **WHEN** an operator opens the credential rule form
- **THEN** the control SHALL offer only `verify`

#### Scenario: A required control is never hidden
- **GIVEN** any provider and auth method combination
- **WHEN** the form requires a field in order to save
- **THEN** that field SHALL be rendered

### Requirement: Credential rules carry operator-supplied CA trust material
A credential rule SHALL accept an optional CA bundle or server certificate
fingerprint so a provider that mandates certificate verification can be used
against an appliance presenting a private or self-signed certificate. Trust
material is public and SHALL NOT be stored as secret material.

#### Scenario: Rule pins a private CA bundle
- **GIVEN** a credential rule with `tls_policy` `verify` and a valid `ca_bundle_pem`
- **WHEN** the plugin connects to a destination presenting a certificate issued by that CA
- **THEN** verification SHALL succeed

#### Scenario: Trust material narrows rather than widens
- **GIVEN** a credential rule with trust material set
- **WHEN** the plugin connects to a destination presenting a publicly-trusted certificate not chaining to that anchor
- **THEN** verification SHALL fail

#### Scenario: Invalid trust material is rejected at write time
- **GIVEN** an operator submitting a rule whose `ca_bundle_pem` does not parse, or has expired, or whose `server_cert_fingerprint` is not `sha256:` followed by 64 hex characters
- **WHEN** the rule is saved
- **THEN** the save SHALL fail with a message naming the invalid field
- **AND** the rule SHALL NOT be persisted

#### Scenario: The two forms are mutually exclusive
- **GIVEN** an operator supplying both `ca_bundle_pem` and `server_cert_fingerprint`
- **WHEN** the rule is saved
- **THEN** the save SHALL fail

### Requirement: Integration credentials are resolved only from the database
No integration credential SHALL be resolvable from an environment variable, a
Kubernetes Secret, or a configuration file.

#### Scenario: Advisory feed requires a credential reference
- **GIVEN** an advisory feed definition with no `credential_ref`
- **WHEN** the feed runs
- **THEN** it SHALL fail with a message directing the operator to the credential rule
- **AND** it SHALL NOT read a token from the process environment
