## ADDED Requirements

### Requirement: Server-Side Local-Login Enforcement

The system SHALL decide whether a successfully password-authenticated user may
complete a local (password) login on the **server**, at the credential acceptance
point, based on the authentication mode, a per-account flag, and an infra
break-glass switch. The decision MUST NOT depend on UI rendering.

The decision function `local_login_allowed?(user, settings)` MUST evaluate, in order:

1. If the break-glass env switch is active, allow.
2. Otherwise, if the account has no password hash, deny.
3. Otherwise, if the resolved auth mode is `password_only`, allow.
4. Otherwise, if the account's `local_login_enabled` flag is true, allow.
5. Otherwise, deny.

The bcrypt password verification MUST run **before** the policy decision so timing is
uniform and the deny path is not an account-enumeration oracle.

#### Scenario: SSO mode denies a regular account with a password
- **GIVEN** auth mode is `active_sso`
- **AND** a user with a valid password and `local_login_enabled = false`
- **WHEN** the user POSTs valid credentials to `/auth/sign-in` or `/auth/local/sign-in`
- **THEN** the server SHALL reject the local login
- **AND** show a generic SSO-required message and redirect toward the SSO entry
- **AND** SHALL NOT create a session

#### Scenario: SSO mode allows an opted-in account
- **GIVEN** auth mode is `active_sso`
- **AND** a user with a valid password and `local_login_enabled = true`
- **WHEN** the user POSTs valid credentials
- **THEN** the server SHALL accept the local login and create a session

#### Scenario: Password-only mode is unchanged
- **GIVEN** auth mode is `password_only`
- **WHEN** any user with a valid password POSTs valid credentials
- **THEN** the server SHALL accept the local login and create a session

#### Scenario: Uniform timing on deny
- **WHEN** a local login is denied by policy
- **THEN** the bcrypt verification SHALL already have executed
- **AND** the response SHALL NOT reveal whether the email exists or the password matched

### Requirement: Fail-Closed Auth-Settings Resolution

The system SHALL fail closed when resolving authentication settings for a local-login
decision. If settings cannot be resolved and the break-glass env switch is off, local
login SHALL be denied (treated as SSO-enforced). The system MUST NOT use a
`password_only`-on-error default to accept a local login.

#### Scenario: Settings unavailable denies a regular account
- **GIVEN** the auth settings cannot be resolved (load error)
- **AND** the break-glass env switch is off
- **AND** a user with `local_login_enabled = false`
- **WHEN** the user POSTs valid credentials
- **THEN** the server SHALL deny the local login

#### Scenario: Settings unavailable still allows an opted-in account
- **GIVEN** the auth settings cannot be resolved (load error)
- **AND** the break-glass env switch is off
- **AND** a user with `local_login_enabled = true`
- **WHEN** the user POSTs valid credentials
- **THEN** the server SHALL accept the local login

#### Scenario: No auto-fallback on IdP unreachable
- **GIVEN** auth mode is `active_sso` and the IdP is unreachable
- **WHEN** a regular user with `local_login_enabled = false` POSTs valid credentials
- **THEN** the server SHALL NOT downgrade to accepting the password

### Requirement: Per-Account Local-Login Opt-In

`ServiceRadar.Identity.User` SHALL have a `local_login_enabled` boolean attribute
(non-nullable, default `false`, public). Local-account creation actions (`:create`,
`:register_with_password`) SHALL set it `true`. SSO/JIT provisioning
(`:provision_sso_user`) SHALL leave it `false`. An admin-only action
`:set_local_login` SHALL allow toggling the flag and SHALL be authorized by the
existing auth-management policy.

#### Scenario: Local registration enables local login
- **WHEN** an account is created via `:create` or `:register_with_password`
- **THEN** `local_login_enabled` SHALL be `true`

#### Scenario: SSO provisioning leaves local login disabled
- **WHEN** an account is provisioned via `:provision_sso_user`
- **THEN** `local_login_enabled` SHALL be `false`

#### Scenario: Admin toggles the flag
- **GIVEN** an admin with the auth-management permission
- **WHEN** the admin invokes `:set_local_login` for a user
- **THEN** the user's `local_login_enabled` SHALL be updated
- **AND** a user without the permission SHALL be denied

### Requirement: Infrastructure Break-Glass Local-Login Switch

The system SHALL provide an environment switch
(`SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN`) that permits local login independent of the
database and the IdP. It MUST be checked first by the local-login decision and always
win. It is a **permit**, not a bypass: a valid password is still required. When
active, the system SHALL render the local sign-in form, log a loud WARNING at boot,
and emit an audit event on each break-glass-permitted local login. An optional
`SERVICERADAR_AUTH_DISABLE_SSO` switch SHALL hide the SSO button.

#### Scenario: Break-glass permits local login when settings are broken
- **GIVEN** `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` is set
- **AND** the auth settings cannot be resolved
- **WHEN** a user POSTs a valid password
- **THEN** the server SHALL accept the local login without a database settings read

#### Scenario: Break-glass still requires a valid password
- **GIVEN** `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` is set
- **WHEN** a user POSTs an invalid password
- **THEN** the server SHALL reject the login

#### Scenario: Break-glass is observable
- **GIVEN** `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` is set
- **WHEN** the application boots
- **THEN** a warning SHALL be logged
- **AND** each break-glass-permitted login SHALL emit an audit event

### Requirement: Retire allow_password_fallback as a Gate

The system SHALL NOT read `AuthSettings.allow_password_fallback` for any local-login
gating decision, and the authentication settings UI SHALL NOT expose it as a toggle.
The column SHALL be retained transitionally for the upgrade backfill only.

#### Scenario: Fallback flag no longer gates login
- **GIVEN** `allow_password_fallback` is set to any value
- **WHEN** the local-login decision is made
- **THEN** the decision SHALL depend only on mode, the per-account flag, and the env switch

#### Scenario: Upgrade preserves current behavior
- **GIVEN** an existing deployment is upgraded
- **WHEN** the migration runs
- **THEN** every account with a password hash whose effective fallback was enabled
  SHALL have `local_login_enabled = true`
- **AND** SSO-only accounts (no password hash) SHALL have `local_login_enabled = false`
</content>
