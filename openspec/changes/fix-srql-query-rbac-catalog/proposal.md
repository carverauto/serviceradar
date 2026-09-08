# Change: Gate SRQL queries on the RBAC permission catalog

## Why

`POST /api/query` (and every other caller of the shared SRQL execute path,
including LiveView SRQL pages and MCP `execute_srql`) authenticates the caller
and then runs read-only SQL against a closed entity list. The actor/scope is
passed through and never consulted. A custom role profile that strips
`devices.view` or an observability `*.view` key can still query those entities
over the API even when the UI would hide them.

This is not tenant isolation and is not a reason to translate SRQL into
Ash.Query. It is a permission-catalog hole (GitHub #4088).

## What Changes

- Map `in:<entity>` (including parser aliases) to the existing RBAC catalog
  key used by the matching UI surface.
- Deny with `{:error, :forbidden}` / HTTP 403 when the caller's scope lacks
  that key.
- Keep `in:dashboards` on the existing Ash/scope dashboard search. Do not
  apply a catalog view key to it.
- Pass `current_scope` on the shared execute path. Do not revive the unused
  `"actor"` request key.
- Do **not** rewrite SRQL onto Ash.Query. Remove that leftover requirement
  from `ash-api` so it cannot be mistaken for the fix.
- Unknown entities still fail in the SRQL compiler (4xx), not as a catalog
  403, so a typo does not look like a permission denial.

## Impact

- Affected specs: `ash-authorization`, `ash-api`, `mcp`
- Affected code: `elixir/web-ng` (`Api.Access`, `SRQL`, `QueryController`,
  tests). No schema migration.
- MCP `execute_srql` inherits the gate because it already calls
  `Access.execute_query/2`.
