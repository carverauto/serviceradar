# Change: Harden MCP SRQL query construction against injection

## Why
GitHub issue #2142 reports that the MCP server constructs SRQL queries by interpolating user-supplied parameters into quoted strings (for example `device_id = '%s'`). Crafted inputs containing quotes and operators can break out of the intended string literal and alter the query semantics.

## What Changes
- Use parameterized SRQL execution for structured scalar parameters so user input is bound as parameters rather than concatenated into SRQL text.
- Update MCP tools and shared query builders to treat identifier parameters as opaque values (not SRQL fragments).
- Add regression tests that prove injection payloads do not widen filters or change the structure of generated SRQL queries.

## Impact
- Affected specs: `mcp` (new)
- Affected code: `pkg/mcp/tools_devices.go`, `pkg/mcp/server.go`, `pkg/mcp/query_utils.go`, `pkg/mcp/builder.go`, `pkg/mcp/tools_logs.go`, `pkg/mcp/tools_events.go`, `pkg/mcp/tools_sweeps.go`
- Compatibility: Behavior should remain the same for normal identifiers; inputs containing quotes no longer alter the WHERE clause structure. MCP deployments MUST provide a query executor that supports parameter binding for structured tools.
- Out of scope: Changing authorization or availability of tools that accept free-form SRQL (for example `srql.query`).
