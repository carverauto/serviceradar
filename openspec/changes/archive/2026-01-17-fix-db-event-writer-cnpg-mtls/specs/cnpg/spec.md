## ADDED Requirements
### Requirement: db-event-writer uses CNPG client certificate for mTLS
The db-event-writer deployment SHALL provide CNPG TLS client certificate and key from the CNPG client certificate bundle (cnpg-client.pem/cnpg-client-key.pem) whenever CNPG client certificate authentication is enabled.

#### Scenario: Helm deployment with client certs
- **GIVEN** Helm values enable CNPG client certificate authentication and mount the CNPG client cert bundle at `/etc/serviceradar/certs`
- **WHEN** `serviceradar-db-event-writer` starts
- **THEN** it connects to CNPG using `cnpg-client.pem` and `cnpg-client-key.pem` for TLS client authentication

#### Scenario: Demo kustomize deployment
- **GIVEN** the demo kustomize manifests enable CNPG client certificate authentication
- **WHEN** `serviceradar-db-event-writer` starts
- **THEN** its CNPG TLS configuration references `cnpg-client.pem` and `cnpg-client-key.pem` and the connection succeeds
