# serviceradar-cli-auth

## ADDED Requirements

### Requirement: Native device-code login
The native Go `serviceradar-cli` SHALL provide an `auth login` command
that authenticates against a ServiceRadar instance using the OAuth 2.0
Device Authorization Grant (RFC 8628) and persists the resulting bearer
token to the shared credential store.

#### Scenario: Successful device-code login
- **WHEN** a user runs `serviceradar-cli auth login --instance https://sr.example.com`
- **THEN** the CLI SHALL `POST /api/v1/cli/auth/device` with
  `client_id: "serviceradar-cli"` and the requested scope (default
  `dashboard.publish`), print the returned `verification_uri`
  (preferring `verification_uri_complete`) and `user_code`, and unless
  `--no-browser` is set, open the verification URL in a browser
- **AND** poll `POST /api/v1/cli/auth/token` with
  `grant_type: urn:ietf:params:oauth:grant-type:device_code` and the
  `device_code` no faster than the server-provided `interval`
- **AND** on a success response persist the `access_token` (with the
  derived `user`, `obtained_at`, and `expires_at`) to the credential
  store and print a confirmation naming the stored path

#### Scenario: Polling honors RFC 8628 pending/slow_down
- **WHEN** the token poll returns HTTP 400 with `error: "authorization_pending"`
- **THEN** the CLI SHALL wait one interval and poll again without error
- **WHEN** the token poll returns HTTP 400 with `error: "slow_down"`
- **THEN** the CLI SHALL increase its poll interval by 5 seconds before
  the next poll

#### Scenario: Polling surfaces terminal errors
- **WHEN** the token poll returns `error: "access_denied"`
- **THEN** the CLI SHALL exit non-zero with a "device login was denied" message
- **WHEN** the token poll returns `error: "expired_token"` or the local
  deadline (from `expires_in`) passes
- **THEN** the CLI SHALL exit non-zero with a device-code-expired message

### Requirement: Manual-token fallback
The `auth login` command SHALL fall back to manual token entry when the
device-code endpoint is not available on the target instance, so
operators can still authenticate against instances that have not deployed
the device-code endpoints.

#### Scenario: Device endpoint returns 404
- **WHEN** `POST /api/v1/cli/auth/device` returns HTTP 404 (or is
  unreachable) during `auth login`
- **THEN** the CLI SHALL print a notice that device-code login is
  unavailable, prompt the user to paste a long-lived token, and persist
  the pasted token to the credential store for the instance

#### Scenario: Existing token passed on the command line
- **WHEN** the user runs `auth login --instance <url> --token <existing>`
- **THEN** the CLI SHALL store the supplied token for the instance
  without contacting the device endpoint

### Requirement: Shared credential store
The Go `serviceradar-cli` SHALL read and write the same on-disk
credential store as the JS dashboard tool so a token minted by either
tool is usable by the other.

#### Scenario: Store location and permissions
- **WHEN** the CLI writes a credential
- **THEN** it SHALL write JSON to `$XDG_CONFIG_HOME/serviceradar/credentials.json`
  (falling back to `~/.config/serviceradar/credentials.json`, and to
  `%APPDATA%\serviceradar\credentials.json` on Windows) with file mode
  `0600` and the layout `{"version":1,"instances":{"<url>":{"token":...,
  "user":...,"obtained_at":...,"expires_at":...,"scope":...}}}` (where
  `scope` is an optional additive field the JS reader ignores)
- **AND** it SHALL refuse to write when the parent directory is group- or
  world-writable on non-Windows platforms

#### Scenario: Cross-tool interoperability
- **WHEN** a credential file was written by `@carverauto/serviceradar-dashboard auth login`
- **THEN** the Go `serviceradar-cli auth status` SHALL read and display it
  without rewriting the file
- **AND** a credential written by the Go CLI SHALL be readable by the JS
  tool's `resolveCredentialToken`

#### Scenario: Instance URL normalization
- **WHEN** an instance URL is stored or looked up
- **THEN** trailing slashes SHALL be trimmed so `https://sr.example.com`
  and `https://sr.example.com/` resolve to the same credential entry

### Requirement: Token resolution precedence
Instance-touching commands SHALL resolve a bearer token using the same
precedence as the JS tool: `--token` flag, then the `SERVICERADAR_TOKEN`
environment variable, then the stored credential for the instance.

#### Scenario: Flag overrides env and store
- **WHEN** `--token` is provided
- **THEN** it SHALL be used regardless of `SERVICERADAR_TOKEN` or any
  stored credential

#### Scenario: Env overrides store
- **WHEN** no `--token` is provided but `SERVICERADAR_TOKEN` is set
- **THEN** the env value SHALL be used over any stored credential

### Requirement: Auth status and logout
The Go `serviceradar-cli` SHALL provide `auth status` and `auth logout`
commands over the shared credential store.

#### Scenario: Status for a single instance
- **WHEN** `auth status --instance <url>` is run and a credential exists
- **THEN** the CLI SHALL print the stored user, obtained-at, and
  expires-at for that instance; when none exists it SHALL report that no
  credential is stored

#### Scenario: Logout removes the credential
- **WHEN** `auth logout --instance <url>` is run
- **THEN** the CLI SHALL delete only that instance's credential entry and
  report whether an entry was removed

### Requirement: Requestable scope set
The `auth login` command SHALL accept a repeatable `--scope` flag and
request the space-joined set as the OAuth `scope`, so operators can obtain
tokens for scopes beyond `dashboard.publish` without a code change. The
granted scope SHALL be recorded with the stored credential.

#### Scenario: Multiple scopes requested
- **WHEN** a user runs `auth login --instance <url> --scope dashboard.publish --scope scan.execute`
- **THEN** the CLI SHALL send `scope: "dashboard.publish scan.execute"` in
  the device-authorization request

#### Scenario: Default scope
- **WHEN** no `--scope` flag is given
- **THEN** the CLI SHALL request `dashboard.publish` (the only scope
  defined today)

### Requirement: Native dashboard publish
The native Go `serviceradar-cli` SHALL provide a `dashboard publish`
command that uploads a pre-built dashboard package to an instance without
requiring Node or the JS toolchain.

#### Scenario: Publish a built package
- **WHEN** a user runs `serviceradar-cli dashboard publish --instance <url> --route ops`
  in a project whose `dist/manifest.json` and renderer artifact exist
- **THEN** the CLI SHALL re-verify the renderer's SHA256 against the
  manifest's `renderer.sha256`, refuse to upload on mismatch, and
  otherwise POST a multipart request (`manifest`, `renderer`, `route`) to
  `POST /api/v1/dashboard-packages` with the resolved bearer token

#### Scenario: Optional enable after publish
- **WHEN** `--enable` is passed and the publish succeeds
- **THEN** the CLI SHALL call `POST /api/v1/dashboard-packages/:id/enable`
  with `{route}` to flip the dashboard live

#### Scenario: Structured server errors are surfaced with hints
- **WHEN** the publish or enable call returns a structured error envelope
  (e.g. `insufficient_scope`, `slug_in_use`, `version_already_published`,
  `unsupported_media_type`, `payload_too_large`, `invalid_route`,
  `rate_limited`)
- **THEN** the CLI SHALL exit non-zero and print an actionable hint for
  that error code rather than only the raw HTTP status

### Requirement: Single canonical `serviceradar-cli` command name
The name `serviceradar-cli` SHALL refer to exactly one tool — the native
Go binary. The JS dashboard-SDK authoring tool SHALL be distributed under
a distinct name and SHALL NOT install a `serviceradar-cli` executable.

#### Scenario: JS tool no longer claims the colliding bin
- **WHEN** the dashboard authoring npm package is installed
- **THEN** it SHALL expose only the `serviceradar-dashboard` executable
  and SHALL NOT expose a `serviceradar-cli` executable

#### Scenario: In-repo references name the correct tool
- **WHEN** repository docs, templates, or help text reference the
  dashboard authoring tool
- **THEN** they SHALL use the `serviceradar-dashboard` name rather than
  `serviceradar-cli`
