# Tasks: Harden MCP SRQL query construction against injection

## 1. Audit and centralize quoting
### 1.1 Inventory unsafe interpolation
- [x] 1.1 Inventory all MCP SRQL builders that interpolate user-controlled string parameters (tools, query utils, generic filter builder).

### 1.2 Add parameterized execution support
- [x] 1.2 Introduce a parameter-capable executor interface (in addition to the existing one) and a helper to execute SRQL with bound params.

## 2. Apply fixes across MCP
- [x] 2.1 Update `devices.getDevice` and `executeGetDevice` to use bound parameters for `device_id` (no raw interpolation).
- [x] 2.2 Update shared query builders to bind `poller_id`, `device_type`, `status`, and timestamp parameters where they are treated as values.
- [x] 2.3 Update the generic filter builder to bind all mapped string fields as values.

## 3. Tests and validation
- [x] 3.1 Add unit tests covering representative injection payloads (quotes, OR, comments) to assert generated queries remain well-formed and structurally unchanged.
- [x] 3.2 Run `openspec validate fix-mcp-srql-sql-injection --strict`.
- [x] 3.3 Run `gofmt` and targeted `go test` for `pkg/mcp` changes.
