## ADDED Requirements

### Requirement: CLI Login Covers Edge Onboarding
The ServiceRadar CLI MUST request the `edge.manage` scope by default when logging in, MUST let the
operator override the requested scopes, and MUST report a server that refuses the requested
scopes or does not support the requested login flow instead of silently degrading.

#### Scenario: Default login requests edge.manage
- **WHEN** an operator runs `auth login` without `--scope`
- **THEN** the device authorization request carries the scopes `dashboard.publish edge.manage`
- **AND** the granted scope is recorded with the stored credential

#### Scenario: Scope override
- **WHEN** an operator runs `auth login --scope "plugin.publish,plugins.manage"`
- **THEN** the request carries exactly `plugin.publish plugins.manage`, space-separated

#### Scenario: Server policy refuses the scope
- **GIVEN** an instance whose CLI auth policy does not allow `edge.manage`
- **WHEN** the operator runs `auth login`
- **THEN** the command fails naming the refused scope and how to proceed
- **AND** no credential is stored

#### Scenario: PKCE not routed
- **GIVEN** an instance that does not route `/api/v1/cli/auth/authorize`
- **WHEN** the operator runs `auth login --web`
- **THEN** the command fails stating the server does not support it and to use the device flow
- **AND** it does not fall back to manual token entry

### Requirement: CLI Edge Onboarding Commands
The ServiceRadar CLI MUST manage agents, edge packages, edge sites, collectors and the NATS account
status of an authenticated instance, with machine-readable `--json` output and human tables by
default.

#### Scenario: Listing agents
- **WHEN** an operator runs `agent list --json`
- **THEN** the CLI prints a JSON array of agents with uid, name, gateway, status, last seen, version and partition
- **AND** it reads the admin agents route, or the JSON:API agents route when the admin route is absent

#### Scenario: Creating an agent package
- **WHEN** an operator runs `edge package create --label <name> --component-type agent`
- **THEN** the CLI creates the package and prints its id and the one-time onboarding token
- **AND** it prints the `edge install agent` command to run on the edge host

#### Scenario: Waiting for a site's leaf bundle
- **GIVEN** an edge site whose leaf server is still being provisioned
- **WHEN** the operator runs `edge site bundle <id> --wait`
- **THEN** the CLI polls while the server answers `409 leaf_not_ready` and saves the bundle once it is served
- **AND** without `--wait` the command fails with a hint to use `--wait`

#### Scenario: Token lacks edge.manage
- **GIVEN** a stored token without the `edge.manage` scope
- **WHEN** the operator runs any edge command and the server answers `403 insufficient_scope`
- **THEN** the error says the token lacks `edge.manage` and to re-run `auth login`

#### Scenario: Rejected token
- **WHEN** the server answers 401
- **THEN** the error tells the operator to re-run `auth login` for that instance

### Requirement: CLI Edge Host Install Helpers
The ServiceRadar CLI MUST provide root-only helpers that install the ServiceRadar package for the
tenant's release on an edge host and apply what the tenant issued for that host, printing every
action before it is taken.

#### Scenario: Installing and enrolling an agent
- **WHEN** root runs `edge install agent --package <id> --token <t> --version <v>`
- **THEN** the CLI downloads `serviceradar-agent-<v>-1.<arch>.rpm` from the `v<v>` GitHub release, installs it with dnf, and runs `srctl enroll --core-url <instance> --token <t>`
- **AND** the token is not echoed in the printed actions

#### Scenario: Dry run
- **WHEN** any install helper runs with `--dry-run`
- **THEN** it prints the planned actions without requiring root and without changing the host or consuming tokens

#### Scenario: Not root
- **WHEN** an install helper runs without root and without `--dry-run`
- **THEN** it fails before taking any action

#### Scenario: Version unknown
- **WHEN** an install helper runs without `--version`
- **THEN** it fails explaining that the release version is required

### Requirement: CLI Bin Name Avoids Edge Package Collision
The CLI package MUST install a bin name that no ServiceRadar system package ships, so it remains
reachable on an edge host where the agent package owns `/usr/local/bin/serviceradar-cli`.

#### Scenario: srcloud alias
- **WHEN** the package is installed globally
- **THEN** `srcloud` runs the same CLI as `serviceradar-cli`
