## ADDED Requirements
### Requirement: SRQL grouped boolean expressions
The SRQL service SHALL support grouped boolean expressions using parentheses and the `OR` keyword, while whitespace between clauses continues to imply AND.

#### Scenario: OR group inside an AND query
- **GIVEN** a devices query with a hostname filter
- **WHEN** a client sends `in:devices (tags.env:prod OR tags.env:stage) hostname:%db%`
- **THEN** SRQL returns devices that match either tag clause and the hostname filter.

#### Scenario: Nested group parsing
- **GIVEN** a query with nested parentheses
- **WHEN** a client sends `in:devices (ip:10.0.0.0/24 OR (vendor_name:Cisco OR vendor_name:Juniper))`
- **THEN** SRQL parses the grouping without changing the meaning of the query.

### Requirement: Sweep criteria builder emits grouped SRQL
The web-ng sweep target criteria builder SHALL allow users to group rules with match-any/all semantics and SHALL emit SRQL that matches the selected grouping.

#### Scenario: Match-any group generates OR
- **GIVEN** a criteria group configured with match-any and two tag rules
- **WHEN** the builder generates SRQL for preview
- **THEN** it produces a parenthesized OR group, for example `(tags.env:prod OR tags.env:stage)`.

### Requirement: Device criteria operators are exposed in the builder
The sweep criteria builder SHALL expose device operators that map to SRQL list membership, numeric comparisons, and IP CIDR/range matching.

#### Scenario: IP CIDR operator
- **GIVEN** a rule with field `ip` and operator `in_cidr`
- **WHEN** the builder generates SRQL
- **THEN** it emits `ip:<cidr>` with proper SRQL escaping.
