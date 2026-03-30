## ADDED Requirements
### Requirement: External DNS authority is explicitly scoped
The shipped `k8s/external-dns` deployment SHALL limit DNS publication authority to the ServiceRadar namespaces and resources that are explicitly intended for external record management.

#### Scenario: Default external-dns render
- **WHEN** the external-dns base manifests are rendered as shipped
- **THEN** the controller only watches the explicit ServiceRadar namespaces configured by the repository
- **AND** it does not publish records for unannotated Services or Ingresses

#### Scenario: Explicit DNS publication
- **WHEN** a Service or Ingress in an allowed namespace carries the external-dns hostname annotation
- **THEN** the controller remains eligible to publish records for that resource within the configured managed zones
