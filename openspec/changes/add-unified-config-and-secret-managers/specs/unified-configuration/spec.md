## ADDED Requirements

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

- **GIVEN** `SERVICERADAR_ENV=onprem:united`
- **WHEN** a component initialises its ConfigManager
- **THEN** it SHALL load the configuration instance for `united`
- **AND** configuration for other on-prem instances SHALL NOT be loaded

#### Scenario: On-prem is selected without an instance

- **GIVEN** `SERVICERADAR_ENV=onprem`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail reporting that `onprem` requires an instance identifier

#### Scenario: An instance is supplied for a single-instance kind

- **GIVEN** `SERVICERADAR_ENV=ci:united`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail reporting that `ci` does not accept an instance identifier

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

### Requirement: Configuration may be loaded from outside this repository

An instance SHALL be loadable from a source outside this repository, so that a deployment whose
topology is not disclosable is not required to publish it. The source SHALL be named by
`SERVICERADAR_CONFIG_URI`. Exactly one of `SERVICERADAR_ENV` and `SERVICERADAR_CONFIG_URI` SHALL be
set; setting both or neither SHALL be a startup error, and there SHALL be no precedence rule
between them.

The loaded artifact SHALL be a binary message. A shipped CLI SHALL compile a text-format instance
to that binary, applying schema validation, the committed rule set, and the credential-shape check,
and SHALL refuse to emit an artifact that fails any of them.

`file:` and `https:` SHALL be supported. `http:` SHALL be rejected. An unrecognised scheme SHALL be
a startup error listing the supported schemes. A failed fetch SHALL be a startup error, and a
previously fetched artifact SHALL NOT be used as a fallback.

Reaching a configuration source SHALL NOT require a ServiceRadar-managed secret; a source requiring
authentication SHALL be reachable with platform-provided workload identity alone. Resolution SHALL
yield the instance together with its provenance.

#### Scenario: A deployment loads configuration from a mounted file

- **GIVEN** `SERVICERADAR_CONFIG_URI=file:///etc/serviceradar/environment.binpb` and
  `SERVICERADAR_ENV` unset
- **WHEN** a component initialises its ConfigManager
- **THEN** it SHALL load that artifact
- **AND** it SHALL validate it against the shipped rule set before returning any value

#### Scenario: Both selectors are set

- **GIVEN** `SERVICERADAR_ENV=onprem:untd` and `SERVICERADAR_CONFIG_URI=file:///etc/env.binpb`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail naming both variables
- **AND** it SHALL NOT choose one of them

#### Scenario: An external instance violates a rule

- **GIVEN** an external artifact whose `database.tls_mode` is `TLS_MODE_DISABLE` for a non-localhost kind
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail listing the violation code and field path
- **AND** no value from that artifact SHALL be returned

#### Scenario: Configuration is offered over cleartext

- **GIVEN** `SERVICERADAR_CONFIG_URI=http://config.internal/environment.binpb`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail rejecting the scheme

#### Scenario: A remote source is unreachable

- **GIVEN** `SERVICERADAR_CONFIG_URI` names an `https:` source that cannot be fetched
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail
- **AND** it SHALL NOT start on a previously fetched artifact

#### Scenario: An invalid instance is compiled

- **GIVEN** a text-format instance omitting a required field
- **WHEN** the CLI compiles it
- **THEN** it SHALL fail listing the violations
- **AND** it SHALL NOT write an output artifact

#### Scenario: An unsupported source scheme is named

- **GIVEN** `SERVICERADAR_CONFIG_URI=srconf://config.internal/environment`
- **WHEN** a component initialises its ConfigManager
- **THEN** startup SHALL fail listing the supported schemes
- **AND** it SHALL NOT fall back to a built-in instance

#### Scenario: Provenance is reported for a resolved value

- **GIVEN** a component that has resolved its configuration from any source
- **WHEN** `explain` is invoked
- **THEN** it SHALL report which source the instance came from
- **AND** it SHALL do so whether the source was built into the release or external
