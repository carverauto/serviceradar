## Context
The MCP server exposes intent-based tools that construct SRQL queries from structured parameters. Several tools/query builders currently build filters using `fmt.Sprintf("field = '%s'", userValue)`, which can be broken by unescaped quotes and allows SRQL/SQL injection via crafted input.

## Goals / Non-Goals
- Goals:
  - Ensure structured scalar parameters are always treated as bound values (not SRQL fragments).
  - Apply the fix consistently across all MCP tools and shared query builders.
  - Add tests that would fail if future changes reintroduce unsafe interpolation.
- Non-Goals:
  - Redesign SRQL syntax/grammar beyond what MCP needs.
  - Introduce new external dependencies or a new security framework.
  - Change authn/authz or disable tools that intentionally accept raw SRQL.

## Decisions
- Decision: Require parameterized SRQL execution for structured scalar tool parameters.
  - Rationale: Quoting/escaping at the SRQL text layer is easy to miss in new code. Binding parameters makes the “value vs expression” boundary explicit and testable.
  - Result: MCP query builders use SRQL placeholders (for example `$1`, `$2`, ...) and pass parameter values out-of-band to the query executor.
- Decision: Treat raw SRQL inputs as pass-through.
  - Rationale: Some tools explicitly accept raw SRQL input (for example `filter` fields or `srql.query`). Altering or binding values inside those strings would change semantics and can introduce placeholder collisions.

## Risks / Trade-offs
- Risk: Parameter support depends on the configured query executor implementation.
  - Mitigation: Make structured tools require a parameter-capable executor; add tests that assert parameter binding is used for those tool paths.

## Migration Plan
- No storage migration.
- Implementation consists of code-only changes in `pkg/mcp` plus tests; roll out as a patch release.

## Open Questions
- Should MCP tools that accept free-form SRQL be restricted or disabled by default to preserve “intent-based” security boundaries?
