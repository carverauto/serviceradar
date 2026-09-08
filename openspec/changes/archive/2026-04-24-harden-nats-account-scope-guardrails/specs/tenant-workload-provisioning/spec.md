## MODIFIED Requirements
### Requirement: Operator NATS account provisioning

The platform bootstrap process SHALL create a dedicated NATS account for the tenant workload operator with least-privilege access to the provisioning stream.

#### Scenario: Operator connects to provisioning stream
- **GIVEN** the operator NATS account is created
- **WHEN** the operator starts
- **THEN** it SHALL authenticate with the operator credentials
- **AND** it SHALL subscribe to the tenant provisioning stream only

#### Scenario: Provisioning credentials stay least-privilege
- **GIVEN** the platform signs NATS credentials for a workload operator or tenant workload
- **WHEN** the request attempts to widen access beyond the approved provisioning or tenant scope
- **THEN** the signing request SHALL be rejected
- **AND** the returned credentials SHALL remain least-privilege for the intended workload role
