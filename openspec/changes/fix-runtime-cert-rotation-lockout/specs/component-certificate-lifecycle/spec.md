## ADDED Requirements

### Requirement: Chart certificate rotation keeps adopted infrastructure admitted
The system SHALL record each runtime certificate that the chart's certificate generator reissues on the adopted infrastructure component that holds the certificate it replaced. It SHALL do so before any workload presents the reissued certificate during a Helm upgrade. It SHALL record a replacement only when the replaced certificate is recorded at the component's current generation and is unrevoked, and only when the replacement has the same issuer. The replacement keeps the component's generation and stored grant, and the replaced certificate stays authorized until it is revoked.

#### Scenario: The certificate layout changes on an upgrade with the callout enabled
- **WHEN** an upgrade reissues every runtime certificate from the same root CA
- **THEN** the pre-upgrade migrations hook records each reissued certificate on the adopted component that held its predecessor
- **AND** every adopted platform component is admitted with its reissued certificate under its existing grant
- **AND** no pre-upgrade hook that connects to NATS runs before that recording

#### Scenario: A reissued certificate is not a successor
- **WHEN** the rotation record names a replacement whose predecessor was never recorded
- **THEN** nothing is recorded for it
- **WHEN** it names a replacement from another issuer, or for a revoked or superseded predecessor
- **THEN** the replacement is refused and the component's recorded certificates are unchanged

#### Scenario: The root CA is reissued
- **WHEN** the callout is enabled together with the certificate regenerator, which reissues the root CA
- **THEN** the chart refuses to render
