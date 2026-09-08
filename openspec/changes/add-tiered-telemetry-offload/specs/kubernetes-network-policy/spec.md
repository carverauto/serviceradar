# kubernetes-network-policy — spec deltas

## ADDED Requirements

### Requirement: Analytics query-head network access is least-privilege
When the analytics query head is enabled, the chart SHALL render NetworkPolicies granting it exactly: ingress from core and web workloads on the PostgreSQL port, egress to the primary database service on the PostgreSQL port, and egress to the configured object-store endpoint. No other ingress or egress SHALL be permitted, and the primary database SHALL admit the analytics head only under the dedicated read-only export role.

#### Scenario: Analytics head enabled
- **WHEN** the analytics head component is enabled
- **THEN** NetworkPolicies restrict it to core/web ingress, primary-database egress, and object-store egress only

#### Scenario: Analytics head disabled
- **WHEN** the component is disabled
- **THEN** no analytics-head NetworkPolicies are rendered and no additional paths to the primary exist
