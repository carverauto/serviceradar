## ADDED Requirements

### Requirement: CLI Plugin Publish
The ServiceRadar CLI MUST publish a built Wasm plugin to an authenticated instance, staging it for
review without requiring browser access or key material.

#### Scenario: Publishing a built plugin stages it
- **GIVEN** a developer with a built `plugin.wasm` and a valid `plugin.yaml`
- **AND** a stored credential for the target instance
- **WHEN** the developer runs the plugin publish command against that instance
- **THEN** the package is created, the bundle is uploaded, and the package is left in `staged`
- **AND** the CLI reports the package id and that an administrator must approve it before use

#### Scenario: Publish requires authentication
- **GIVEN** no stored credential and no token supplied for the target instance
- **WHEN** the developer runs the plugin publish command
- **THEN** the command fails before any upload
- **AND** the error names the login command to run

#### Scenario: Publish refuses a stale build
- **GIVEN** a `plugin.wasm` whose digest does not match the digest recorded for the build
- **WHEN** the developer runs the plugin publish command
- **THEN** the command fails before any upload
- **AND** the error directs the developer to rebuild

#### Scenario: Publish reports an authorization failure distinctly
- **GIVEN** a credential for a user who does not hold the permission to stage plugin packages
- **WHEN** the developer runs the plugin publish command
- **THEN** the command fails with an authorization error naming the missing permission
- **AND** it does not report the failure as a network or server error

#### Scenario: Upload failure does not leave an orphaned package
- **GIVEN** a package that was created but whose bundle upload then fails
- **WHEN** the command exits
- **THEN** the CLI reports the package id and its incomplete state
- **AND** the developer is told how to retry or remove it

### Requirement: CLI Plugin Scaffolding And Validation
The ServiceRadar CLI MUST scaffold new plugin projects for the supported SDK languages and MUST
validate a plugin project locally without network access.

#### Scenario: Scaffolding a Go plugin project
- **WHEN** a developer initializes a new plugin project selecting the Go template
- **THEN** a buildable project depending on the Go SDK is created
- **AND** the printed next steps include how to build and publish it

#### Scenario: Scaffolding a Rust plugin project
- **WHEN** a developer initializes a new plugin project selecting the Rust template
- **THEN** a buildable project depending on the Rust SDK is created
- **AND** the printed next steps include how to build and publish it

#### Scenario: Local validation makes no network calls
- **GIVEN** a plugin project with an invalid manifest
- **WHEN** the developer runs the plugin validate command
- **THEN** the manifest errors are reported
- **AND** no request is made to any instance

### Requirement: CLI Token Scope Enforcement On Plugin Publishing
The system MUST constrain CLI-issued tokens to the scope they were granted when they are used
against plugin package endpoints.

#### Scenario: Plugin publish scope is grantable to the CLI
- **WHEN** the CLI requests device authorization for the plugin publishing scope
- **THEN** the authorization is issued
- **AND** the approving user sees which scope is being granted

#### Scenario: A token granted only dashboard scope cannot publish plugins
- **GIVEN** a CLI token granted only the dashboard publishing scope
- **WHEN** it is presented to a plugin package endpoint
- **THEN** the request is refused on scope grounds
- **AND** the refusal does not depend on the user's plugin permissions

#### Scenario: Existing API keys are unaffected
- **GIVEN** a non-OAuth API key whose user holds the permission to stage plugin packages
- **WHEN** it is presented to a plugin package endpoint
- **THEN** the request is authorized as it was before this change
