# unified-configuration Specification

## Purpose
TBD - created by archiving change add-unified-config-and-secret-managers. Update Purpose after archive.
## Requirements
### Requirement: Single environment selector with compound identity

Every ServiceRadar component SHALL determine its configuration from exactly one environment
variable, `SERVICERADAR_ENV`, whose value is an environment identity of the form
`<kind>[":" <instance>]`. The kinds SHALL be `localhost`, `ci`, `saas`, `demo`, and `onprem`. The
`onprem` kind SHALL require an instance identifier naming the deployment; the other kinds SHALL NOT
accept one.

Components SHALL NOT read per-setting environment variables for any value covered by the
configuration schema. An unset, unparseable, or unrecognised identity SHALL be a startup error
naming the invalid value and listing the accepted kinds, and SHALL NOT fall back to a default.

#### Scenario: Component starts with a single-instance kind

- **GIVEN** `SERVICERADAR_ENV=ci`
- **WHEN** a component initialises its ConfigManager
- **THEN** it SHALL load the `ci` configuration
- **AND** it SHALL NOT consult any per-setting environment variable for a schema-covered value

#### Scenario: Component starts with an on-prem instance

- **GIVEN** `SERVICERADAR_ENV=onprem:acme`
- **WHEN** a component initialises its ConfigManager
- **THEN** it SHALL load the configuration instance for `acme`
- **AND** configuration for other on-prem instances SHALL NOT be loaded

#### Scenario: On-prem is selected without an instance

- **GIVEN** `SERVICERADAR_ENV=onprem`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail reporting that `onprem` requires an instance identifier

#### Scenario: An instance is supplied for a single-instance kind

- **GIVEN** `SERVICERADAR_ENV=ci:acme`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail reporting that `ci` does not accept an instance identifier

#### Scenario: A configuration file names an instance for a single-instance kind

- **GIVEN** a committed instance whose kind is not `onprem` and which sets an instance identifier
- **WHEN** validation runs
- **THEN** it SHALL report a violation on the `instance` field

#### Scenario: Environment variable is unset

- **GIVEN** `SERVICERADAR_ENV` is not set
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail with an error listing `localhost`, `ci`, `saas`, `demo`, `onprem`

#### Scenario: Environment identity is misspelled

- **GIVEN** `SERVICERADAR_ENV=CI-staging`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail naming the unrecognised value

### Requirement: Rules and completeness checks range over every instance

Rules SHALL declare the environment scope over which they apply — all kinds, a named subset, or
every instance of a kind. Completeness checks SHALL be evaluated against every configuration
instance, including each on-prem instance, so that an instance omitting a required field fails
validation.

#### Scenario: A new on-prem instance omits a required field

- **GIVEN** a new on-prem instance configuration missing a required field
- **WHEN** validation runs over all instances
- **THEN** it SHALL fail naming the instance and the missing field

#### Scenario: An invariant is asserted across instances

- **GIVEN** a rule requiring verified TLS in every environment except `localhost`
- **WHEN** an on-prem instance sets a weaker TLS mode
- **THEN** validation SHALL fail naming that instance

### Requirement: Schema and configuration files are committed ground truth

Configuration SHALL be defined by a protobuf schema under `config/proto/`, with one text-format
instance per environment under `config/environments/`. The schema SHALL be the sole definition of
which settings exist; the instances SHALL be the sole source of their values. Configuration files
SHALL NOT contain secrets.

Fields that must be present SHALL use explicit presence, and every enum SHALL reserve its zero value
as an `*_UNSPECIFIED` sentinel that validation rejects. Decoding SHALL NOT substitute a type default
for an absent value.

The committed text-format instance SHALL be the authored ground truth. A build action SHALL compile
each instance to a binary message, and implementations SHALL load the binary rather than parsing
text format. A test SHALL assert that each generated binary corresponds to its committed source.

#### Scenario: A setting is added

- **WHEN** a new setting is added to the schema
- **THEN** it SHALL be available to the Rust, Go, and Elixir implementations from the same generated
  definition
- **AND** no language-specific name for that setting SHALL be introduced

#### Scenario: A required field is omitted from a file

- **GIVEN** an environment file that omits a field declared with explicit presence
- **WHEN** validation runs
- **THEN** it SHALL report the field as absent
- **AND** it SHALL NOT treat the type default as a supplied value

#### Scenario: An enum is left unset

- **GIVEN** an environment file that does not set a TLS mode
- **WHEN** validation runs
- **THEN** it SHALL reject the `*_UNSPECIFIED` sentinel rather than accept the first defined value

#### Scenario: An instance is compiled for loading

- **GIVEN** a committed text-format instance
- **WHEN** the build runs
- **THEN** it SHALL produce a binary message for that instance
- **AND** implementations SHALL load the binary without parsing text format

#### Scenario: A generated binary diverges from its source

- **GIVEN** a generated binary that does not correspond to its committed text-format source
- **WHEN** the round-trip test runs
- **THEN** it SHALL fail naming the instance

#### Scenario: A configuration file contains a secret

- **GIVEN** a configuration file containing a password, private key, or a connection string with
  embedded credentials
- **WHEN** validation runs
- **THEN** it SHALL fail and identify the offending field

### Requirement: Validation is a committed rule set over a closed predicate vocabulary

Validation SHALL be expressed as committed data, not as per-language code. Each rule SHALL name a
field path, a predicate, its parameters, a phase, and a stable violation code. Predicates SHALL be
drawn from a closed, documented vocabulary; adding a predicate SHALL require extending that
vocabulary explicitly. Each predicate SHALL be a pure, total function of its value and parameters,
with no ambient state and no partiality.

#### Scenario: A rule is added

- **WHEN** a constraint is added to the rule set
- **THEN** every implementation SHALL enforce it without any implementation being modified

#### Scenario: A predicate receives an unexpected input

- **GIVEN** a predicate applied to an absent field or a value of the wrong type
- **WHEN** it is evaluated
- **THEN** it SHALL return a defined verdict
- **AND** it SHALL NOT panic, raise, or return an implementation-specific result

### Requirement: Rules declare an evaluation phase

Each rule SHALL declare whether it is evaluated against configuration files alone, against
configuration resolved together with secrets, or both. Build-time validation SHALL evaluate only
file-phase rules. Runtime validation SHALL evaluate all rules applicable to the resolved
configuration.

#### Scenario: A secret-dependent rule at build time

- **GIVEN** a rule requiring a resolved password to be non-empty
- **WHEN** build-time configuration validation runs
- **THEN** the rule SHALL be skipped as out of phase
- **AND** validation SHALL NOT fail merely because the secret is unavailable

#### Scenario: A file-phase rule at startup

- **GIVEN** a rule requiring every environment to define a database host
- **WHEN** a component resolves configuration at startup
- **THEN** the rule SHALL be evaluated against the loaded file

### Requirement: Implementations are verified by shared vectors and property tests

The managers SHALL be implemented natively in Rust, Go, and Elixir, with no runtime dependency on
another language's implementation. Each SHALL be verified by a committed conformance vector file and
by property-based tests over the predicate laws. Vectors SHALL assert violation identity — the
stable code and field path — and not merely acceptance or rejection. The order of reported
violations SHALL be deterministic. Both suites SHALL run in the default test sweep.

#### Scenario: Implementations disagree on a verdict

- **GIVEN** a conformance vector and its expected violations
- **WHEN** an implementation returns a different verdict
- **THEN** its conformance suite SHALL fail

#### Scenario: Implementations agree on rejection but not on reason

- **GIVEN** an input that every implementation rejects
- **WHEN** one reports a different violation code or field path than the vector specifies
- **THEN** that implementation's conformance suite SHALL fail

#### Scenario: A predicate law is violated

- **GIVEN** the law that `one_of` accepts a value if and only if it is a member of the permitted set
- **WHEN** property-based testing generates a counterexample
- **THEN** the test SHALL fail and report the generated input

#### Scenario: A new predicate is added without vectors

- **WHEN** a predicate is added to the vocabulary with no conformance vectors
- **THEN** the suite SHALL fail

### Requirement: The rule set defends itself against silent weakening

Every rule SHALL have at least one committed fixture that violates it and MUST be rejected. Every
field in the schema SHALL be covered by at least one rule. Removing or weakening a rule, or adding a
field with no rule, SHALL cause a test to fail.

#### Scenario: A rule is deleted

- **GIVEN** a rule with a committed violating fixture
- **WHEN** the rule is removed from the rule set
- **THEN** the fixture SHALL now be accepted
- **AND** the negative-fixture test SHALL fail

#### Scenario: A field is added with no rule

- **WHEN** a field is added to the schema and no rule references it
- **THEN** the coverage check SHALL fail naming the uncovered field

### Requirement: Least privilege for configuration and secrets

Bazel targets SHALL declare the configuration they consume as `data` dependencies rather than
receiving values through the ambient environment. Each component SHALL declare the logical secret
names it may request, and the secret provider SHALL refuse any request for an undeclared name. Only
secrets SHALL be forwarded to test actions.

#### Scenario: A target consumes configuration

- **GIVEN** a test target that declares database configuration as `data`
- **WHEN** it is built
- **THEN** that configuration SHALL appear in its runfiles
- **AND** configuration it did not declare SHALL NOT be present

#### Scenario: A component requests an undeclared secret

- **GIVEN** a component whose manifest does not declare `nats.client_key`
- **WHEN** it requests that secret
- **THEN** the provider SHALL refuse the request and report the undeclared name

#### Scenario: The forwarding allow-list is bounded

- **WHEN** the environment forwarding profile is reviewed
- **THEN** it SHALL contain only secret-bearing names
- **AND** an automated check SHALL confirm every name in it is read by code

### Requirement: Secrets resolve through a per-environment provider

`SecretManager` SHALL resolve secrets by logical name through a provider selected by
`SERVICERADAR_ENV`. Logical names SHALL be identical across environments and languages. An
unresolvable secret SHALL be a hard error naming the logical key and the provider, and SHALL NOT
yield a default or empty value. Rules over secrets SHALL constrain shape only — presence, length, or
format — and SHALL NOT embed secret values or hashes of them.

#### Scenario: Secret is missing in CI

- **GIVEN** `SERVICERADAR_ENV=ci` and no stored entry for `database.password`
- **WHEN** a component requests that secret
- **THEN** resolution SHALL fail naming `database.password` and the CI provider
- **AND** the component SHALL NOT proceed with an empty password

#### Scenario: The same logical name works everywhere

- **GIVEN** the logical secret `database.password`
- **WHEN** it is requested under each environment
- **THEN** each provider SHALL resolve it from its own backing store
- **AND** no caller SHALL need to know the platform-specific key name

### Requirement: Composite values are assembled, never stored

Values combining configuration and secrets, such as PostgreSQL connection strings, SHALL be assembled
at runtime from typed configuration fields and resolved secrets. A composite containing a credential
SHALL NOT be stored in a configuration file, a secret store entry, or an environment variable. TLS
mode SHALL be a typed field, not a string appended to a URL. Database role names SHALL be
configuration fields and SHALL NOT be recovered by parsing a connection string; the connecting role
and the owning role SHALL be separately addressable.

#### Scenario: Database connection string is built

- **GIVEN** configuration providing host, port, database, TLS mode, and TLS server name, and secrets
  providing the password
- **WHEN** a component requests a database connection
- **THEN** the manager SHALL assemble the DSN from those parts
- **AND** the assembled DSN SHALL NOT appear in any configuration file

#### Scenario: The owning role is read as configuration

- **GIVEN** an environment whose configuration names the role owning per-run databases
- **WHEN** the provisioning lifecycle needs that owner
- **THEN** it SHALL read the configured field directly
- **AND** it SHALL NOT parse a credential-bearing connection string to recover it

#### Scenario: TLS mode cannot be silently weakened

- **GIVEN** an environment whose configuration sets verified TLS
- **WHEN** a connection is established
- **THEN** the typed TLS mode SHALL be carried through to the client
- **AND** no code path SHALL omit or downgrade it by string manipulation

### Requirement: Resolution fails closed and is explainable

A component SHALL resolve every configuration value and secret it declares at startup, before
serving traffic or running assertions, and SHALL fail if any is missing or invalid. The platform
SHALL provide a command that prints the fully resolved configuration for an environment and
component, showing the provenance of each value, with secrets redacted.

#### Scenario: A declared value is missing at startup

- **GIVEN** a component declaring a setting absent from its environment
- **WHEN** it starts
- **THEN** startup SHALL fail naming the setting, the environment, and the source consulted
- **AND** the failure SHALL occur at startup rather than at first use

#### Scenario: An operator inspects resolution

- **WHEN** an operator runs the explain command for an environment and component
- **THEN** it SHALL print each resolved value with the file or provider it came from
- **AND** secret values SHALL be redacted

### Requirement: The environment variable is required and its absence is explained

`SERVICERADAR_ENV` SHALL be the only environment variable a component reads to determine its
configuration. It SHALL have no default. When it is unset or empty, startup SHALL fail with a
message that names the variable, states that nothing can be loaded without it, lists every
accepted value, and shows how to set it on each supported platform.

#### Scenario: The variable is not set

- **GIVEN** `SERVICERADAR_ENV` is unset
- **WHEN** a component starts
- **THEN** startup SHALL fail naming `SERVICERADAR_ENV`
- **AND** the message SHALL list `localhost`, `ci`, `saas`, `demo` and `onprem:<instance>`
- **AND** the message SHALL show how to set it under Kubernetes, Docker, Compose, CI and local
  development
- **AND** it SHALL NOT fall back to any default environment

#### Scenario: The variable is set to an empty value

- **GIVEN** `SERVICERADAR_ENV=""`
- **WHEN** a component starts
- **THEN** it SHALL be treated as unset rather than as an environment kind

### Requirement: The instance source follows from the environment kind

The location an instance is read from SHALL be derived from the kind, not from a second variable.
Kinds with no provisioning platform SHALL carry their instance in the artifact; deployed kinds
SHALL read a mounted artifact at a constant path. A deployment whose topology is not disclosable
SHALL be supported by mounting its own compiled instance at that path.

#### Scenario: A deployed environment reads its mount

- **GIVEN** `SERVICERADAR_ENV=saas` and a compiled instance mounted at the constant path
- **WHEN** a component initialises its ConfigManager
- **THEN** it SHALL load that artifact
- **AND** it SHALL validate it against the shipped rule set before returning any value

#### Scenario: The mounted artifact is absent

- **GIVEN** `SERVICERADAR_ENV=saas` and no artifact at the mount path
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail naming the path
- **AND** it SHALL NOT start on any previously read artifact

#### Scenario: An on-prem deployment supplies its own instance

- **GIVEN** `SERVICERADAR_ENV=onprem:<id>` and that deployment's compiled instance mounted at the
  constant path
- **WHEN** a component initialises its ConfigManager
- **THEN** it SHALL load and validate it
- **AND** no part of that deployment's topology SHALL be required to exist in this repository

### Requirement: A loaded instance must describe the selected environment

The `kind` and `instance` of a loaded artifact SHALL match the identity named by
`SERVICERADAR_ENV`. A mismatch SHALL be a startup error naming both the selected identity and the
one found.

#### Scenario: The wrong artifact is mounted

- **GIVEN** `SERVICERADAR_ENV=demo` and a mounted artifact whose `kind` is `ENVIRONMENT_KIND_SAAS`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail naming both `demo` and `saas`
- **AND** no value from that artifact SHALL be returned

#### Scenario: Another deployment's on-prem instance is mounted

- **GIVEN** `SERVICERADAR_ENV=onprem:untd` and a mounted artifact whose `instance` is a different
  identifier
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail naming both identifiers

### Requirement: Resolution reports where a value came from

Resolution SHALL yield the instance together with its source, whether that source is carried in
the artifact or mounted. Reaching a configuration source SHALL NOT require a ServiceRadar-managed
secret; a source requiring authentication SHALL be reachable with platform-provided workload
identity alone.

#### Scenario: Provenance is reported for a resolved value

- **GIVEN** a component that has resolved its configuration
- **WHEN** `explain` is invoked
- **THEN** it SHALL report which source the instance came from

