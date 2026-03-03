## ADDED Requirements

### Requirement: CSRF Token Comparisons MUST Use Constant-Time Functions
All comparisons of CSRF tokens, OAuth state parameters, and other security-sensitive strings MUST use constant-time comparison (`Plug.Crypto.secure_compare/2`) to prevent timing side-channel attacks.

#### Scenario: SAML CSRF token validation uses constant-time comparison
- **WHEN** a SAML ACS callback compares the RelayState CSRF token against the stored session token
- **THEN** the comparison MUST use `Plug.Crypto.secure_compare/2` rather than `!=` or `==`

#### Scenario: OIDC state validation uses constant-time comparison
- **WHEN** an OIDC callback compares the state parameter against the stored session state
- **THEN** the comparison MUST use `Plug.Crypto.secure_compare/2` rather than `!=` or `==`

### Requirement: User-Controlled Input MUST NOT Create Atoms
URL parameters, form inputs, and other user-controlled strings MUST NOT be converted to atoms via `String.to_atom/1`. Use `String.to_existing_atom/1` with error handling or keep values as strings.

#### Scenario: Unknown node name handled gracefully
- **WHEN** a user navigates to a node page with a `node_name` parameter that does not correspond to an existing atom
- **THEN** the system MUST display an error message without crashing the BEAM VM
- **AND** the system MUST NOT create a new atom from the user-supplied string

### Requirement: Post-Login Redirects MUST Be Validated
The `return_to` redirect target used after successful authentication MUST be validated to ensure it is a safe, relative path within the application. External URLs, protocol-relative URLs, and backslash-prefixed URLs MUST be rejected.

#### Scenario: Valid relative path accepted
- **WHEN** a user logs in with `return_to=/analytics`
- **THEN** the user is redirected to `/analytics`

#### Scenario: External URL rejected
- **WHEN** a user logs in with `return_to=https://evil.com/steal`
- **THEN** the user is redirected to the default path (`/analytics`) instead

#### Scenario: Protocol-relative URL rejected
- **WHEN** a user logs in with `return_to=//evil.com/steal`
- **THEN** the user is redirected to the default path instead

### Requirement: WebSocket Connections MUST Require Authentication
The UserSocket `connect/3` callback MUST verify a valid JWT session token before accepting a connection. Unauthenticated connections MUST be rejected. The socket MUST expose a user-specific `id` for targeted disconnect capability.

#### Scenario: Authenticated user connects successfully
- **WHEN** a user with a valid session token opens a WebSocket connection
- **THEN** the connection is accepted and the user is assigned to the socket

#### Scenario: Unauthenticated client rejected
- **WHEN** a client without a valid session token attempts a WebSocket connection
- **THEN** the connection MUST be rejected

### Requirement: Channel Joins MUST Verify User Presence
Phoenix channel `join/3` callbacks MUST verify that the socket has an authenticated user assigned before allowing the join. Feature-flag checks alone are insufficient.

#### Scenario: Topology channel requires authenticated socket
- **WHEN** a socket without `current_user` assigned attempts to join `topology:god_view`
- **THEN** the join MUST be rejected with an `unauthorized` error

### Requirement: Error Responses MUST NOT Leak Internal Details
Error responses sent to clients MUST use generic error messages. Internal Elixir structures, module names, and stack traces MUST NOT be exposed via `inspect/1` or similar serialization in client-facing responses. Detailed errors MUST be logged server-side only.

#### Scenario: Topology snapshot error returns generic message
- **WHEN** a god-view snapshot build fails
- **THEN** the HTTP response contains a generic error like `"snapshot_build_failed"` without internal details
- **AND** the detailed error is logged server-side

### Requirement: Chart Tooltip HTML MUST Escape Data-Derived Values
All JavaScript chart tooltip code that builds HTML strings via template literals and assigns them to `innerHTML` MUST pass data-derived values through `escapeHtml()` before interpolation to prevent stored XSS.

#### Scenario: Malicious metric label is neutralized
- **WHEN** a timeseries chart renders a tooltip for a series whose label contains `<img onerror=alert(1)>`
- **THEN** the HTML entities are escaped and the script does not execute

#### Scenario: Malicious netflow source name is neutralized
- **WHEN** a Sankey or Icicle chart renders a tooltip for a flow whose source name contains HTML tags
- **THEN** the HTML entities are escaped and no injection occurs
