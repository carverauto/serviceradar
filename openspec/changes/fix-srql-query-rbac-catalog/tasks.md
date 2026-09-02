## 1. Shared gate

- [x] 1.1 Add `ServiceRadarWebNG.SRQL.EntityAccess` mapping `in:<entity>`
      (including parser aliases) to RBAC catalog keys. Dashboards passthrough.
      Unknown entities passthrough to the compiler.
- [x] 1.2 Call the gate from `Api.Access.execute_query/2` before
      `query_request/1`, always putting `current_scope` on the request.
- [x] 1.3 Call the same gate from `SRQL.query_request/1` and
      `SRQL.query_arrow/2` so LiveView and dashboard frames cannot skip Access.
- [x] 1.4 `QueryController` returns HTTP 403 (not 400) for `:forbidden`.

## 2. Spec leftover

- [x] 2.1 Replace the `ash-api` "SRQL to Ash Query Translation" requirement
      with a catalog-gate requirement. Do not implement Ash.Query translation.

## 3. Tests

- [x] 3.1 db_free: mapping covers every `SRQL.Catalog.entities/0` id;
      aliases resolve; injection-shaped uid is irrelevant here; missing
      `devices.view` forbids `in:devices`; `in:logs` allowed; `in:dashboards`
      passthrough; unknown entity passthrough.
- [x] 3.2 ConnCase: custom `RoleProfile` without `devices.view` gets 403 on
      `POST /api/query` `in:devices`; without `observability.logs.view` gets
      403 on `in:logs`; built-in viewer still 200 on `in:devices`;
      `in:dashboards` is not 403 from this gate.
- [x] 3.3 Stub `query_request` asserts `"scope"` is present (drop-on-floor
      regression).
- [x] 3.4 MCP `execute_srql` with a token whose user lacks `devices.view`
      returns a tool error, not rows.

## 4. Validate

- [x] 4.1 `openspec validate fix-srql-query-rbac-catalog --strict`
