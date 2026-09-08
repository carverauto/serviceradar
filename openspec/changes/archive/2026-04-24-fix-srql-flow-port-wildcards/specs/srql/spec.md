## ADDED Requirements

### Requirement: Flow port filters support wildcard patterns
The SRQL service SHALL support wildcard pattern matching for flow port fields (`src_port`, `dst_port`, `src_endpoint_port`, `dst_endpoint_port`) when the query uses `%` patterns for contains/starts_with/ends_with semantics. Equality and list operators SHALL continue to require integer values.

#### Scenario: Wildcard dst_port filter
- **GIVEN** flows exist with `dst_port` values `443` and `8443`
- **WHEN** a client sends `in:flows dst_port:%443%`
- **THEN** SRQL executes successfully and returns flows with port values containing `443`

#### Scenario: Wildcard src_port filter with starts_with
- **GIVEN** flows exist with `src_port` values `53` and `5353`
- **WHEN** a client sends `in:flows src_port:53%`
- **THEN** SRQL returns flows with port values starting with `53`

#### Scenario: Equality port filter still requires integer
- **GIVEN** a flows query uses equality on `dst_port`
- **WHEN** a client sends `in:flows dst_port:abc`
- **THEN** SRQL returns an invalid request error indicating the port must be an integer
