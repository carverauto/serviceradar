# Wasm Plugin System

## ADDED Requirements

### Requirement: Plugin egress to private address space is declared, not inherited
A Wasm plugin manifest SHALL declare the private address space it is permitted to
reach in `allowed_networks`. A wildcard in `allowed_domains` SHALL NOT grant
reachability to an IP-literal destination.

#### Scenario: Wildcard domain does not reach a literal private IP
- **GIVEN** a plugin manifest with `allowed_domains: ["*"]` and no `allowed_networks`
- **WHEN** the plugin requests `https://192.168.1.1/`
- **THEN** the agent SHALL deny the request
- **AND** the plugin SHALL receive the denied error code, not a transport error

#### Scenario: Declared network permits the destination
- **GIVEN** a plugin manifest declaring `allowed_networks` covering `192.168.0.0/16`
- **WHEN** the plugin requests `https://192.168.1.1/` on a permitted port
- **THEN** the agent SHALL allow the request

#### Scenario: Link-local remains unreachable
- **GIVEN** a plugin manifest declaring RFC1918 and CGNAT ranges
- **WHEN** the plugin requests a `169.254.0.0/16` destination
- **THEN** the agent SHALL deny the request

### Requirement: Egress denials are legible to the operator
An egress denial SHALL be distinguishable from a transport failure in the agent
log and in any plugin result derived from it.

#### Scenario: Denial is logged with cause
- **GIVEN** a plugin request denied by the egress policy
- **WHEN** the agent records the denial
- **THEN** the log entry SHALL name the destination and whether the host or the port gate failed

#### Scenario: Plugin result carries the reason
- **GIVEN** a plugin whose collection failed only because egress was denied
- **WHEN** the plugin reports a CRITICAL result
- **THEN** the summary SHALL include the underlying collection error rather than a bare zero count

### Requirement: Command-bridge plugins are not scheduled
A plugin whose configuration is supplied per-dispatch SHALL declare
`action-only:v1` so the agent schedules no periodic runner for it.

#### Scenario: Command bridge is not periodically invoked
- **GIVEN** a plugin package declaring `action-only:v1`
- **WHEN** the agent materialises the assignment
- **THEN** the agent SHALL NOT schedule a periodic `run_check` for that assignment
