## MODIFIED Requirements
### Requirement: MCP tool parameters are quoted as SRQL literals
The MCP server MUST treat structured tool parameters that represent scalar string values (for example identifiers, names, and timestamps) as bound values when constructing SRQL queries, and MUST NOT concatenate raw parameter text into SRQL fragments.

#### Scenario: Device ID input cannot widen a query
- **GIVEN** a `devices.getDevice` request with `device_id` containing quotes and operators (for example `device' OR '1'='1`)
- **WHEN** the MCP server constructs the SRQL query
- **THEN** the query compares `device_id` to a single bound value representing the entire input value
- **AND** the query structure is not modified by the input (no additional boolean conditions are introduced)

#### Scenario: Gateway ID input cannot escape its filter
- **GIVEN** a request that filters by `gateway_id` via a structured parameter (not a raw SRQL filter string)
- **WHEN** the MCP server constructs the SRQL query
- **THEN** `gateway_id` is represented as a bound value and cannot terminate or extend the filter expression

### Requirement: Free-form SRQL is explicitly opt-in
Tools that accept free-form SRQL strings MUST explicitly label the parameter as raw SRQL input (for example `query` or `filter`) and MUST document that the value is passed through. Tools that accept structured scalar parameters MUST NOT interpret those parameters as SRQL fragments.

#### Scenario: Structured parameters are not treated as raw SRQL
- **GIVEN** a tool that accepts `device_id` or `gateway_id` as a structured parameter
- **WHEN** the parameter contains SRQL operators
- **THEN** the parameter is treated as a literal value, not parsed as SRQL syntax
