## ADDED Requirements

### Requirement: MCP execute_srql uses the shared SRQL catalog gate
MCP `execute_srql` SHALL call the same shared execute function as
`POST /api/query` and SHALL NOT run SRQL when the caller's scope lacks the
mapped RBAC view key. The tool MUST NOT return rows for a forbidden entity.

#### Scenario: MCP cannot bypass the catalog gate
- **GIVEN** MCP is enabled
- **AND** the authenticated user lacks `devices.view`
- **WHEN** the client calls `execute_srql` with `in:devices`
- **THEN** the tool result is an error
- **AND** no device rows are returned
