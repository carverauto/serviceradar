## REMOVED Requirements

### Requirement: SRQL to Ash Query Translation
**Reason**: Never implemented. Translating device SRQL into Ash.Query to get
"tenant isolation" fights the dedicated-deployment model (CNPG `search_path`)
and is the wrong fix for GitHub #4088. Device Ash policies are
permission-level, not row-level.
**Migration**: SRQL stays on the Rust NIF → parameterized SQL path. Entity
access is gated by the RBAC catalog (see ash-authorization). Metrics and
other SQL entities are unchanged.

## ADDED Requirements

### Requirement: SRQL HTTP query enforces the RBAC catalog
`POST /api/query` SHALL apply the same entity-to-permission catalog gate as
the rest of the shared SRQL execute path. Authorization failures SHALL be
HTTP 403 with a JSON `error` of `forbidden`, not HTTP 400.

#### Scenario: Forbidden SRQL is 403
- **GIVEN** an authenticated API client whose user lacks `devices.view`
- **WHEN** the client POSTs `{"query":"in:devices"}` to `/api/query`
- **THEN** the status is 403
- **AND** the body includes `"error":"forbidden"`
- **AND** the status is not 400 or 500
