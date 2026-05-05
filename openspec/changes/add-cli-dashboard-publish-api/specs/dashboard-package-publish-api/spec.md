## ADDED Requirements

### Requirement: HTTP publish endpoint
The system SHALL expose `POST /api/v1/dashboard-packages` accepting a `multipart/form-data` body with three parts — `manifest` (`application/json`), `renderer` (`application/javascript`, `text/javascript`, or `application/wasm`), and `route` (text slug). On success it SHALL return HTTP 200 with `{id, dashboard_id, version, route_slug, status, content_hash}` so the client can compose a deterministic enable URL without re-querying.

#### Scenario: CLI publishes a fresh package and slug
- **GIVEN** a CLI session JWT carrying scope `dashboard.publish` and a user with the `cli.dashboard.publish` RBAC permission
- **AND** a local dashboard whose manifest declares `id: com.example.foo`, `version: 0.1.0`, and a renderer SHA256 that matches the uploaded renderer bytes
- **AND** no `DashboardInstance` row currently binds the route slug `example-foo`
- **WHEN** the CLI POSTs the manifest + renderer + `route=example-foo` to `/api/v1/dashboard-packages`
- **THEN** the system SHALL persist a `DashboardPackage` row keyed on `(com.example.foo, 0.1.0)`
- **AND** it SHALL persist a `DashboardInstance` row binding `route_slug=example-foo` to that package with `enabled=false`
- **AND** it SHALL respond 200 with a JSON body containing the persisted `id`, `dashboard_id`, `version`, `route_slug`, `status`, and `content_hash`
- **AND** the response SHALL be returned even if the audit-log write fails (audit is best-effort)

#### Scenario: Publish without a route slug succeeds and creates no instance binding
- **GIVEN** a publishing client that omits the `route` form field
- **WHEN** the CLI POSTs the manifest + renderer to `/api/v1/dashboard-packages`
- **THEN** the system SHALL persist the `DashboardPackage` row
- **AND** it SHALL NOT create a `DashboardInstance` row
- **AND** the response SHALL contain a null `route_slug`

#### Scenario: Manifest renderer.sha256 does not match uploaded bytes
- **GIVEN** a publishing client whose manifest claims a renderer SHA256 that disagrees with the SHA256 of the uploaded renderer part
- **WHEN** the CLI POSTs to `/api/v1/dashboard-packages`
- **THEN** the system SHALL respond HTTP 422 with body `{"error":"unprocessable_renderer","reason":"sha256_mismatch"}`
- **AND** it SHALL NOT persist any package or instance row

### Requirement: HTTP enable endpoint
The system SHALL expose `POST /api/v1/dashboard-packages/:id/enable` accepting an optional JSON body `{"route": <slug>?}` and SHALL flip the addressed package to `status: :enabled`. When `route` is provided, the system SHALL bind (or re-bind) the named slug to the package per the slug-ownership rules.

#### Scenario: Enable an existing disabled package
- **GIVEN** a `DashboardPackage` with `id=PKG`, `status=:disabled`, `verification_status="verified"`
- **AND** a caller with the `cli.dashboard.enable` RBAC permission and JWT scope `dashboard.publish`
- **WHEN** the caller POSTs to `/api/v1/dashboard-packages/PKG/enable` with body `{}`
- **THEN** the system SHALL set the package status to `:enabled`
- **AND** it SHALL respond 200 with the updated package row

#### Scenario: Enable rebinds the slug to the addressed package
- **GIVEN** a slug `example-foo` bound to `DashboardPackage` A with `enabled=true`
- **AND** a `DashboardPackage` B with the same `dashboard_id` as A and a higher `version`
- **WHEN** the caller POSTs to `/api/v1/dashboard-packages/B/enable` with body `{"route":"example-foo"}`
- **THEN** the slug `example-foo` SHALL be bound to package B with `enabled=true`
- **AND** package A SHALL be left at `status=:enabled` but the slug binding row SHALL no longer reference A

#### Scenario: Enable refuses to take a slug owned by a different dashboard_id
- **GIVEN** a slug `example-foo` bound to `DashboardPackage` A whose `dashboard_id=com.example.foo` and `enabled=true`
- **AND** a `DashboardPackage` C with `dashboard_id=com.other.foo`
- **WHEN** the caller POSTs to `/api/v1/dashboard-packages/C/enable` with body `{"route":"example-foo"}`
- **THEN** the system SHALL respond HTTP 409 with body `{"error":"slug_in_use","route":"example-foo","owner_dashboard_id":"com.example.foo"}`
- **AND** package C SHALL remain in its previous status
- **AND** the slug binding for A SHALL NOT be modified

### Requirement: HTTP disable endpoint
The system SHALL expose `POST /api/v1/dashboard-packages/:id/disable` accepting an empty JSON body and SHALL flip the addressed package to `status: :disabled` without deleting it or its instance bindings.

#### Scenario: Disable an enabled package
- **GIVEN** a `DashboardPackage` with `id=PKG`, `status=:enabled`
- **AND** a caller with the `cli.dashboard.disable` RBAC permission and JWT scope `dashboard.publish`
- **WHEN** the caller POSTs to `/api/v1/dashboard-packages/PKG/disable`
- **THEN** the system SHALL set the package status to `:disabled`
- **AND** the corresponding `DashboardInstance` rows SHALL be left intact (rows persist, `enabled` flag flips per existing semantics)
- **AND** subsequent GETs to `/api/v1/dashboard-packages/PKG/renderer` SHALL fail with 404 because the package is no longer enabled

### Requirement: Defense-in-depth scope and permission gate
Every publish, enable, and disable request SHALL pass three independent checks before any state-changing work runs: a Phoenix authentication pipeline check, a token-scope plug check, and an RBAC permission check. Any single failure SHALL reject the request before the controller reads the multipart body or the JSON body.

#### Scenario: Bearer JWT missing the `dashboard.publish` scope is rejected
- **GIVEN** a Guardian JWT with `typ: "api"` and `scopes: ["read"]`
- **AND** a user with the `cli.dashboard.publish` RBAC permission
- **WHEN** the caller POSTs to `/api/v1/dashboard-packages` with that JWT
- **THEN** the system SHALL respond HTTP 403 with body `{"error":"insufficient_scope","required":"dashboard.publish"}`
- **AND** the controller SHALL NOT have read the multipart body

#### Scenario: User missing the `cli.dashboard.publish` RBAC permission is rejected
- **GIVEN** a Guardian JWT with `scopes: ["dashboard.publish"]`
- **AND** a user whose role does not grant `cli.dashboard.publish`
- **WHEN** the caller POSTs to `/api/v1/dashboard-packages` with that JWT
- **THEN** the system SHALL respond HTTP 403 with body `{"error":"forbidden","permission":"cli.dashboard.publish"}`
- **AND** no DB rows SHALL be written

#### Scenario: Session-authenticated LiveView upload uses the fallback permission
- **GIVEN** a session-authenticated admin (no `oauth_token_scope` assign present)
- **AND** that admin has the `plugins.stage` RBAC permission today
- **WHEN** the existing Settings → Dashboard Packages LiveView upload modal posts a manifest + renderer
- **THEN** the system SHALL accept the upload via the existing context path
- **AND** the new defense-in-depth plug SHALL NOT cause a regression on the LiveView path

### Requirement: Slug ownership invariant
A `DashboardInstance.route_slug` row SHALL belong to at most one `dashboard_id` while `enabled=true`. The publish/enable endpoints SHALL refuse any operation that would bind a slug currently `enabled=true` for one `dashboard_id` to a different `dashboard_id`.

#### Scenario: Concurrent publishes to the same fresh slug serialize
- **GIVEN** two CLI clients publishing concurrently with the same `route=example-foo` from manifests with different `dashboard_id` values
- **AND** no existing `DashboardInstance` row for that slug
- **WHEN** both POSTs land within the same multi-millisecond window
- **THEN** exactly one publish SHALL succeed with HTTP 200
- **AND** the other publish SHALL receive HTTP 409 `slug_in_use`
- **AND** the rejected publish SHALL NOT have written its `DashboardPackage` row, OR if it did write the package, it SHALL NOT have written the slug binding (the binding is the contended row; the package is keyed independently on `(dashboard_id, version)`)

#### Scenario: A disabled binding for a different dashboard_id is replaceable
- **GIVEN** a `DashboardInstance` row binding `example-foo` to package A (`dashboard_id=com.a.x`) with `enabled=false`
- **AND** a fresh publish with `dashboard_id=com.b.y` and `route=example-foo`
- **WHEN** the publish is POSTed
- **THEN** the system SHALL succeed and create a new binding row for `com.b.y`
- **AND** the prior binding row for `com.a.x` SHALL remain (rows persist, only `enabled` and the active link change)

### Requirement: Version-overwrite invariant
A `DashboardPackage` row keyed on `(dashboard_id, version)` SHALL NOT have its persisted `content_hash` silently replaced. Re-publishes of the same `dashboard_id@version` SHALL be a noop when bytes match, SHALL be allowed when the existing row is `:disabled` (resetting verification), and SHALL be rejected when the existing row is `:enabled` or `verification_status="verified"` and the bytes differ.

#### Scenario: Idempotent re-publish with identical bytes
- **GIVEN** an existing `DashboardPackage` row for `com.example.foo@0.1.0` with `content_hash=H`
- **WHEN** the CLI publishes the same `id@version` whose renderer SHA256 also resolves to `H`
- **THEN** the system SHALL respond HTTP 200 with the existing row
- **AND** the persisted `content_hash` SHALL remain `H`
- **AND** the system SHALL NOT mark the package row as updated by the operation (it MAY update only the `updated_at` timestamp)

#### Scenario: Re-publish to an enabled package with new bytes is rejected
- **GIVEN** an existing enabled `DashboardPackage` row for `com.example.foo@0.1.0` with `content_hash=H1`
- **WHEN** the CLI publishes the same `id@version` with bytes whose SHA256 is `H2 != H1`
- **THEN** the system SHALL respond HTTP 409 with body `{"error":"version_already_published","existing_content_hash":"H1"}`
- **AND** the persisted package SHALL remain at `content_hash=H1`

#### Scenario: Re-publish to a disabled package with new bytes resets verification
- **GIVEN** an existing `DashboardPackage` row for `com.example.foo@0.1.0` with `status=:disabled` and `content_hash=H1`
- **WHEN** the CLI publishes the same `id@version` with new bytes whose SHA256 is `H2`
- **THEN** the system SHALL update the row to `content_hash=H2`
- **AND** it SHALL reset `verification_status` to `"pending"`
- **AND** the package SHALL remain `status=:disabled` until an explicit enable call

### Requirement: Multipart hardening
The publish endpoint SHALL enforce per-part size and content-type caps and SHALL reject requests that exceed them before any disk write.

#### Scenario: Manifest exceeds 256 KB
- **WHEN** the CLI posts a manifest part larger than 256 KB
- **THEN** the system SHALL respond HTTP 413 `{"error":"payload_too_large","part":"manifest"}`
- **AND** it SHALL NOT have read the renderer part

#### Scenario: Renderer exceeds the configured cap
- **GIVEN** `Storage.max_upload_bytes()` returns 50 MB
- **WHEN** the CLI posts a renderer part larger than 50 MB
- **THEN** the system SHALL respond HTTP 413 `{"error":"payload_too_large","part":"renderer"}`

#### Scenario: Renderer with disallowed content-type is rejected
- **WHEN** the CLI posts a renderer part with `content-type: application/octet-stream`
- **THEN** the system SHALL respond HTTP 415 `{"error":"unsupported_media_type","part":"renderer"}`

#### Scenario: Route slug fails the regex
- **WHEN** the CLI posts `route=Bad/Slug.exe`
- **THEN** the system SHALL respond HTTP 400 `{"error":"invalid_route","reason":"route_slug must match ^[a-z0-9][a-z0-9-]{1,62}$"}`
- **AND** no DB write SHALL be attempted

### Requirement: Rate limiting
The publish endpoint SHALL be rate-limited per CLI-session JWT (`jti`) to prevent a single leaked token from being used as a publish-DDOS vector.

#### Scenario: Eleventh publish in 60 s on the same jti
- **GIVEN** a CLI session JWT that has successfully published 10 packages in the last 60 seconds
- **WHEN** the same JWT POSTs an eleventh publish
- **THEN** the system SHALL respond HTTP 429 with body `{"error":"rate_limited","retry_after":<seconds>}`
- **AND** the response SHALL include a `Retry-After` header
- **AND** subsequent enable/disable calls on the same JWT SHALL NOT count against the publish budget

### Requirement: Audit logging
Every state-changing publish, enable, and disable hop SHALL emit one audit row capturing the actor, the JWT id, the operation, and the resulting state. Audit failures SHALL NOT cause the request to fail.

#### Scenario: A successful publish writes an audit row
- **WHEN** a publish succeeds
- **THEN** the audit sink SHALL receive an entry with `{actor_user_id, jti, action: :dashboard_publish, dashboard_id, version, route_slug, content_hash, ip, result: :written}`

#### Scenario: A rejected publish writes an audit row
- **WHEN** a publish is rejected for `slug_in_use`
- **THEN** the audit sink SHALL receive an entry with `result: :rejected, reason: "slug_in_use"` and the same actor + jti fields

### Requirement: RBAC catalog additions
The system SHALL register three new RBAC permissions in a `dashboards` section of the catalog: `cli.dashboard.publish`, `cli.dashboard.enable`, `cli.dashboard.disable`. Each SHALL default to admin role only.

#### Scenario: Default role assignment
- **WHEN** a fresh deployment seeds its RBAC catalog
- **THEN** the catalog SHALL contain a `dashboards` section
- **AND** that section SHALL contain `cli.dashboard.publish`, `cli.dashboard.enable`, and `cli.dashboard.disable`
- **AND** each permission's `default_roles` SHALL list only `admin`

#### Scenario: Existing roles do not gain CLI publish capability silently
- **GIVEN** an upgrade where the catalog seed runs after this proposal lands
- **WHEN** the seed completes
- **THEN** users with `operator` or `viewer` roles SHALL NOT have any of the three new permissions
- **AND** assigning them SHALL require an explicit role-grant action by an admin
