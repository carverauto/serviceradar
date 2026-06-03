## ADDED Requirements

### Requirement: Endpoint Inventory Force-Fresh RBAC
The platform SHALL define an explicit `endpoint_inventory.force_fresh_scan` permission for triggering device-scoped fresh endpoint inventory scans.

#### Scenario: Force-fresh denied without permission
- **GIVEN** an authenticated operator lacks `endpoint_inventory.force_fresh_scan`
- **WHEN** they request a force-fresh endpoint inventory scan
- **THEN** the control plane SHALL deny the request before command dispatch
- **AND** it SHALL record an authorization denial according to the platform security event conventions

#### Scenario: Force-fresh allowed with permission and policy
- **GIVEN** an authenticated operator has `endpoint_inventory.force_fresh_scan`
- **AND** endpoint inventory policy enables force-fresh for the target device and sources
- **WHEN** they request a force-fresh endpoint inventory scan
- **THEN** the control plane MAY dispatch the command subject to command-bus capacity and rate limits

#### Scenario: Cache-query uses normal inventory read authorization
- **GIVEN** an operator requests an endpoint inventory cache query
- **WHEN** the control plane authorizes the request
- **THEN** it SHALL use normal inventory read authorization
- **AND** it SHALL NOT require the force-fresh permission unless the request asks the agent to rescan
