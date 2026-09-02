# mcp

## ADDED Requirements

### Requirement: Sweep diagnostics are discoverable through MCP

The MCP SRQL tools SHALL surface the sweep diagnostics entities through the
existing generic query and documentation tools, without adding sweep-specific
tools.

#### Scenario: Sweep entities appear in the catalog
- **GIVEN** an MCP client calling the SRQL catalog tool
- **WHEN** it requests a sweep diagnostics entity
- **THEN** the entity's fields, enums and control tokens SHALL be returned
- **AND** the entity SHALL appear in the generated entity list

#### Scenario: Sweep recipes are discoverable by task
- **GIVEN** an MCP client looking up SRQL documentation for sweeps
- **WHEN** it searches for sweep, scan or port coverage
- **THEN** recipes SHALL be returned for identifying which sweep groups target a
  device, whether TCP was requested or dropped during compilation, and which
  agent last wrote a device's availability

#### Scenario: No new MCP tools are introduced
- **GIVEN** the existing generic SRQL execute, catalog and lookup tools
- **WHEN** sweep diagnostics are exposed
- **THEN** they SHALL be reachable through those tools
- **AND** no sweep-specific MCP tool SHALL be added

#### Scenario: Documented retention prevents a false negative
- **GIVEN** an operator querying raw sweep results beyond their retention window
- **WHEN** the catalog documentation for the entity is read
- **THEN** the retention window SHALL be stated
- **AND** the operator SHALL be directed to the coverage rollup entity for older
  history, so an empty result is not mistaken for an absence of sweep activity

### Requirement: MCP sweep diagnostics respect authorization boundaries

Sweep diagnostics reached through MCP SHALL be subject to the same partition and
authorization boundaries as any other SRQL entity, and SHALL NOT expose
credential material.

#### Scenario: Compiled sweep config is not readable without admin scope
- **GIVEN** an MCP caller without administrative scope
- **WHEN** it queries the compiled sweep config entity
- **THEN** the query SHALL be denied

#### Scenario: Sweep diagnostics carry no credentials
- **GIVEN** any sweep diagnostics entity reached through MCP
- **WHEN** results are returned
- **THEN** no community string, credential secret or compiled config document
  SHALL be present in the response
