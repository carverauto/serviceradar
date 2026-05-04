## ADDED Requirements

### Requirement: Device authorization endpoint
The ServiceRadar API SHALL expose `POST /api/v1/cli/auth/device` that mints a device authorization for the OAuth 2.0 Device Authorization Grant (RFC 8628) and returns the device code, user code, verification URLs, expiry, and recommended polling interval.

#### Scenario: CLI requests a device authorization
- **GIVEN** a ServiceRadar instance with the CLI auth endpoints deployed
- **WHEN** `POST /api/v1/cli/auth/device` is called with `client_id=serviceradar-cli` and `scope=dashboard.publish`
- **THEN** the server SHALL respond `200 OK` with a JSON body containing `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in`, and `interval`
- **AND** the `verification_uri_complete` SHALL be `${instance_url}/cli/auth/device?user_code=<user-code>`
- **AND** the persisted device authorization row SHALL store only the SHA-256 hash of `device_code`, never the plaintext

#### Scenario: Unsupported client id
- **GIVEN** a request body with `client_id=unknown-client`
- **WHEN** `POST /api/v1/cli/auth/device` is called
- **THEN** the server SHALL respond `400 Bad Request` with `error: invalid_client`

#### Scenario: Rate limit exhausted
- **GIVEN** a single client IP that has already requested 10 device authorizations within the last 60 seconds
- **WHEN** the eleventh `POST /api/v1/cli/auth/device` arrives in the same window
- **THEN** the server SHALL respond `429 Too Many Requests` with `error: rate_limited` and a `retry_after` field

### Requirement: Token polling endpoint
The ServiceRadar API SHALL expose `POST /api/v1/cli/auth/token` that the CLI polls with the device code, returning RFC 8628 §3.5 error codes while the authorization is pending or expired, and returning a Guardian-issued JWT after the user approves.

#### Scenario: Polling while pending
- **GIVEN** a device authorization that has been minted but not yet approved
- **WHEN** the CLI polls `POST /api/v1/cli/auth/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code` and the device code
- **THEN** the server SHALL respond `400 Bad Request` with `error: authorization_pending`

#### Scenario: User approves
- **GIVEN** a device authorization the user has just approved through the in-browser LiveView
- **WHEN** the CLI's next poll arrives at the token endpoint
- **THEN** the server SHALL issue a Guardian JWT with `typ: "api"`, the requested scopes, and a configurable TTL (default 30 days)
- **AND** the response SHALL match `{access_token, token_type: "Bearer", expires_in, scope, user: {id, email}}`
- **AND** the issuing `cli_sessions` row SHALL be persisted with the JWT's `jti` so the session can be revoked later

#### Scenario: User denies
- **GIVEN** a device authorization the user denied through the LiveView
- **WHEN** the CLI polls
- **THEN** the server SHALL respond `400 Bad Request` with `error: access_denied`

#### Scenario: Device code expired
- **GIVEN** a device authorization whose `expires_at` is in the past
- **WHEN** the CLI polls
- **THEN** the server SHALL respond `400 Bad Request` with `error: expired_token`

#### Scenario: Polling too fast
- **GIVEN** a device authorization that the CLI is polling faster than the recommended interval
- **WHEN** two polls arrive within the same `cli_auth_token` rate-limit window for the same `device_code`
- **THEN** the server SHALL respond `400 Bad Request` with `error: slow_down`
- **AND** the device authorization row's `interval_seconds` SHALL increase by 5 seconds for the next poll

### Requirement: User-facing approval LiveView
The ServiceRadar web UI SHALL host a `/cli/auth/device` LiveView that lets a signed-in user approve or deny a device authorization by entering its user code, with redirect-to-log-in handling for unauthenticated visitors.

#### Scenario: Unauthenticated user follows verification URL
- **GIVEN** an unauthenticated visitor opens `/cli/auth/device?user_code=WDJB-MJHT`
- **WHEN** the LiveView renders
- **THEN** the LiveView SHALL redirect to the existing log-in page with `return_to=/cli/auth/device?user_code=WDJB-MJHT`
- **AND** after log-in the visitor SHALL land back on the approval form with the user code still pre-filled

#### Scenario: User approves
- **GIVEN** a signed-in user on the approval form for a pending user code
- **WHEN** the user clicks "Approve"
- **THEN** the matching device authorization row SHALL transition to `status: approved` and store the user's id
- **AND** the page SHALL display a success state and a link to the Settings → CLI sessions page

#### Scenario: User denies
- **GIVEN** a signed-in user on the approval form for a pending user code
- **WHEN** the user clicks "Deny"
- **THEN** the matching device authorization row SHALL transition to `status: denied`
- **AND** the polling CLI SHALL receive `error: access_denied` on its next poll

#### Scenario: Code already expired
- **GIVEN** a signed-in user pasting a user code whose row has `expires_at` in the past
- **WHEN** the LiveView renders
- **THEN** the LiveView SHALL display an "expired code" message and refuse to surface Approve / Deny buttons

### Requirement: CLI sessions Settings page
The ServiceRadar Settings UI SHALL provide a "CLI sessions" page that lists every CLI-issued JWT for the current user (admin sees all users) and lets the user revoke individual sessions.

#### Scenario: User views their CLI sessions
- **GIVEN** a signed-in user with two active CLI sessions
- **WHEN** the user navigates to Settings → CLI sessions
- **THEN** the page SHALL render one row per session with the issuing client name, scope, issued-at, last-used-at, expires-at, and status

#### Scenario: User revokes an active session
- **GIVEN** a signed-in user on the CLI sessions page with one active session
- **WHEN** the user clicks Revoke
- **THEN** the matching `cli_sessions` row SHALL transition to `status: revoked`
- **AND** any subsequent API request bearing the revoked JWT SHALL be rejected with `401 Unauthorized`

#### Scenario: Admin sees other users' sessions
- **GIVEN** a signed-in admin
- **WHEN** the admin navigates to Settings → CLI sessions
- **THEN** the page SHALL surface a "User" column and SHALL list sessions for every user
- **AND** the admin SHALL be able to revoke any session from that view

### Requirement: Revoked JWT enforcement
The existing `ApiAuth` plug SHALL reject Guardian-issued JWTs whose `jti` belongs to a revoked or expired `cli_sessions` row, even when the JWT itself is otherwise valid and unexpired.

#### Scenario: Revoked JWT used for an API call
- **GIVEN** a CLI session whose `cli_sessions` row has been transitioned to `status: revoked`
- **WHEN** any subsequent ServiceRadar API request arrives bearing the JWT issued from that session
- **THEN** the `ApiAuth` plug SHALL respond `401 Unauthorized`
- **AND** the rejection SHALL not require waiting for the JWT's natural `expires_at`

#### Scenario: Active JWT validates without DB load on the hot path
- **GIVEN** a CLI session whose JWT is valid and whose `cli_sessions` row is `status: active`
- **WHEN** the JWT is presented on multiple API requests within the cache TTL
- **THEN** the revocation lookup SHALL come from an in-process cache (no DB round-trip per request)
- **AND** revoking the session SHALL invalidate the cache entry so the next request 401s

### Requirement: RBAC controls for CLI authentication
The CLI authentication surface SHALL be gated by RBAC permissions named `cli.session.create`, `cli.session.read_own`, `cli.session.revoke_own`, `cli.session.read_any`, `cli.session.revoke_any`, and `cli.policy.manage`, plus instance-level `cli_auth_enabled`, `cli_session_ttl_days`, and `cli_allowed_scopes` settings on the existing `AuthorizationSettings` resource.

#### Scenario: User without `cli.session.create` opens the approval page
- **GIVEN** a signed-in user whose role grants neither `cli.session.create` nor admin
- **WHEN** the user navigates to `/cli/auth/device?user_code=WDJB-MJHT`
- **THEN** the LiveView SHALL render an explanatory error state ("your role does not allow CLI authentication; ask an admin")
- **AND** the LiveView SHALL NOT surface Approve or Deny buttons
- **AND** the polling CLI SHALL eventually receive `error: expired_token` once the device authorization's TTL elapses

#### Scenario: Issued JWT cannot exceed approving user's permissions
- **GIVEN** a user with operator-level permissions approves a device authorization that requested `scope=admin`
- **WHEN** the token endpoint mints the JWT
- **THEN** the JWT's permission claims SHALL be drawn from the approving user's actual permission set, not the requested scope
- **AND** subsequent API requests bearing this JWT SHALL be authorized as the operator user, never as an admin

#### Scenario: Instance disables the CLI auth flow
- **GIVEN** an admin has set `AuthorizationSettings.cli_auth_enabled = false`
- **WHEN** any client calls `POST /api/v1/cli/auth/device` or `POST /api/v1/cli/auth/token`
- **THEN** the server SHALL respond `503 Service Unavailable` with `error: cli_auth_disabled`
- **AND** the CLI SHALL fall back to manual-token paste per its existing behavior

#### Scenario: Requested scope outside the allow-list
- **GIVEN** an instance with `AuthorizationSettings.cli_allowed_scopes = ["dashboard.publish"]`
- **WHEN** `POST /api/v1/cli/auth/device` is called with `scope=admin`
- **THEN** the server SHALL respond `400 Bad Request` with `error: invalid_scope`

#### Scenario: User without `cli.session.read_any` views Settings → CLI sessions
- **GIVEN** a non-admin user on the Settings → CLI sessions page
- **WHEN** the page renders
- **THEN** the page SHALL list only the user's own CLI sessions
- **AND** no "User" column SHALL appear

#### Scenario: Admin views Settings → CLI sessions
- **GIVEN** an admin user on the Settings → CLI sessions page
- **WHEN** the page renders
- **THEN** the page SHALL list every user's CLI sessions
- **AND** a "User" column SHALL be visible
- **AND** Revoke buttons SHALL be enabled for any row

#### Scenario: Admin policy panel gated on `cli.policy.manage`
- **GIVEN** a user without `cli.policy.manage`
- **WHEN** the user navigates to the "CLI authentication" admin sub-page
- **THEN** the page SHALL respond with the standard "you do not have access" rendering used elsewhere in the Settings UI

### Requirement: Cleanup of stale device authorizations and sessions
The ServiceRadar deployment SHALL run a scheduled cleanup that expires pending device authorizations past their TTL, expires `cli_sessions` whose JWTs have passed their natural `expires_at`, and hard-deletes terminal rows older than 90 days.

#### Scenario: Pending row passes its expiry
- **GIVEN** a `device_authorizations` row with `status: pending` and `expires_at < now()`
- **WHEN** the daily cleanup job runs
- **THEN** the row SHALL transition to `status: expired`

#### Scenario: Approved session passes its JWT TTL
- **GIVEN** a `cli_sessions` row with `status: active` whose JWT `expires_at` is in the past
- **WHEN** the daily cleanup job runs
- **THEN** the row SHALL transition to `status: expired`

#### Scenario: Terminal rows older than 90 days
- **GIVEN** a `device_authorizations` or `cli_sessions` row in any terminal status older than 90 days
- **WHEN** the daily cleanup job runs
- **THEN** the row SHALL be hard-deleted from the database
