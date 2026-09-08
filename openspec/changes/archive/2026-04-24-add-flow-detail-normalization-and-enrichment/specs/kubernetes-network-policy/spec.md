## ADDED Requirements

### Requirement: Demo network policy SHALL allow egress for enrichment dataset refreshes
When dataset refresh jobs are enabled for flow enrichment, demo Helm values SHALL include explicit `networkPolicy.egress.allowedCIDRs` entries needed to reach external dataset sources used by provider CIDR and IEEE OUI refresh jobs.

#### Scenario: Demo values include enrichment source egress CIDRs
- **GIVEN** `values-demo.yaml` enables network policy egress controls
- **WHEN** provider CIDR and OUI refresh jobs are configured
- **THEN** `networkPolicy.egress.allowedCIDRs` includes CIDR entries required for the configured enrichment dataset endpoints
- **AND** values comments document the endpoint mapping and resolution date

#### Scenario: Rendered demo policy permits enrichment egress
- **GIVEN** the chart is rendered with `values-demo.yaml`
- **WHEN** Kubernetes and Calico network policies are generated
- **THEN** the rendered egress rules include the enrichment dataset CIDR allow-list
- **AND** pods remain default-deny for egress destinations outside the explicit allow-list
