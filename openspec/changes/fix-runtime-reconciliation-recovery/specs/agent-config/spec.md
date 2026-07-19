## ADDED Requirements

### Requirement: Provider policy rejection is fail-closed and stable
The control plane SHALL validate provider-specific credential transport and auth
policy before issuing a broker grant or materializing an assignment. A known
fail-closed policy rejection SHALL be reported as a stable skip reason rather than
an agent execution failure, while unexpected errors SHALL remain failures.

#### Scenario: Legacy Proxmox rule disables TLS verification
- **GIVEN** an enabled Proxmox credential rule requests `skip_verify`
- **WHEN** periodic credential reconciliation evaluates the rule for an agent
- **THEN** no credential grant or plugin assignment SHALL be created
- **AND** the summary SHALL count `proxmox_tls_verification_required`
- **AND** the agent SHALL NOT be counted as failed solely because of that policy

#### Scenario: Unexpected materialization error remains actionable
- **GIVEN** a provider rule passes its policy preflight
- **WHEN** grant issuance or assignment materialization fails unexpectedly
- **THEN** reconciliation SHALL fail for that agent
- **AND** the error SHALL remain visible in logs and telemetry
