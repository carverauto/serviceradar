## ADDED Requirements

### Requirement: Every component resolves schema-covered values through the managers

Every ServiceRadar component SHALL obtain each schema-covered value from `ConfigManager` or
`SecretManager`, and SHALL NOT read a per-setting environment variable for such a value. An
automated build check SHALL fail when a direct retrieval call (`env::var`, `System.get_env`,
`os.Getenv`) reappears for a schema-covered name.

Values that vary by build or checkout rather than by environment are NOT schema-covered and SHALL
remain declared build inputs.

#### Scenario: A reintroduced direct read fails the build

- **GIVEN** a component that resolves its database coordinates through ConfigManager
- **WHEN** a change adds a direct read of a schema-covered environment variable to that component
- **THEN** the build check SHALL fail naming the file and the variable

#### Scenario: A test action receives only the selector and its declared secrets

- **GIVEN** a Bazel test target that reaches the shared fixture
- **WHEN** the target is invoked with `SERVICERADAR_ENV` and its declared `SERVICERADAR_SECRET_*`
  variables
- **THEN** the test SHALL resolve host, port, roles and TLS posture from the compiled instance in
  its runfiles
- **AND** it SHALL NOT require any per-setting variable to be forwarded

#### Scenario: A value that varies by checkout is not moved into the schema

- **GIVEN** a path to test data inside the build tree
- **WHEN** the migration considers it
- **THEN** it SHALL remain a declared build input resolved through runfiles
- **AND** it SHALL NOT acquire a schema field or an environment override

### Requirement: Secrets resolve from the environment in every implementation

Each of the Rust, Go and Elixir SecretManager implementations SHALL provide an environment-backed
provider that maps a logical secret name to a variable by the same total transform, and the
environment SHALL select that provider for every kind except `localhost`.

An empty variable SHALL be treated as absent rather than as an empty credential.

#### Scenario: A Go component resolves a declared secret from the environment

- **GIVEN** `SERVICERADAR_ENV=ci` and `SERVICERADAR_SECRET_DATABASE_PASSWORD` set
- **WHEN** a Go component resolves the declared name `database.password`
- **THEN** it SHALL return the value from that variable
- **AND** the variable name SHALL be computed from the logical name, not looked up in a table

#### Scenario: An empty secret variable does not resolve

- **GIVEN** `SERVICERADAR_SECRET_DATABASE_PASSWORD` set to the empty string
- **WHEN** any implementation resolves `database.password`
- **THEN** resolution SHALL fail naming the secret and the provider consulted
- **AND** it SHALL NOT return an empty credential

#### Scenario: The three implementations agree on the variable name

- **GIVEN** the logical name `database.admin_password`
- **WHEN** each implementation computes its variable
- **THEN** all three SHALL yield `SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD`

### Requirement: Deployed environments carry their instance and their selector

Every deployment SHALL set `SERVICERADAR_ENV`, and every deployed environment kind SHALL have its
compiled instance available at the mounted instance path. A component whose instance is absent
SHALL fail at startup naming the source it consulted, and SHALL NOT fall back to a default
configuration.

#### Scenario: A deployed workload loads its mounted instance

- **GIVEN** a workload deployed with `SERVICERADAR_ENV=demo`
- **WHEN** it initialises its ConfigManager
- **THEN** it SHALL read the compiled instance from the mounted instance path
- **AND** the instance SHALL be rejected if it describes a different environment

#### Scenario: A missing mount is a startup error

- **GIVEN** a workload deployed with a deployed kind and no mounted instance
- **WHEN** it initialises its ConfigManager
- **THEN** startup SHALL fail naming the path consulted
- **AND** it SHALL NOT start with default or partial configuration
