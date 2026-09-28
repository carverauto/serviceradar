## ADDED Requirements

### Requirement: The installed version of a dashboard package is discoverable
A ServiceRadar instance SHALL expose which dashboard packages are installed and at
what version, readable without publishing anything and without fetching the
renderer bytes.

#### Scenario: Listing what is installed
- **GIVEN** an instance with one or more published dashboard packages
- **WHEN** an authorised caller asks the instance for its dashboard packages
- **THEN** the response SHALL report, for each package, the manifest id, the version, and whether it is enabled
- **AND** it SHALL report the route the package is served at where one is bound

#### Scenario: Asking about one package by the identifier its author knows
- **GIVEN** a package published with the manifest id `com.example.thing`
- **WHEN** an authorised caller asks the instance about `com.example.thing`
- **THEN** the instance SHALL report that package
- **AND** it SHALL NOT require the caller to know an instance-internal identifier instead

#### Scenario: Asking about a package that is not installed
- **GIVEN** an instance with no package matching the requested identifier
- **WHEN** an authorised caller asks about it
- **THEN** the instance SHALL report that it is not installed
- **AND** the response SHALL be distinguishable from the endpoint itself being absent

#### Scenario: Reading does not require the right to publish
- **GIVEN** a caller authorised to view dashboard packages but not to publish them
- **WHEN** they ask which packages are installed
- **THEN** the request SHALL succeed
- **AND** it SHALL NOT require a publish-scoped credential

#### Scenario: Signing material and storage layout are not exposed
- **GIVEN** a package whose stored record includes signature material and an object-storage key
- **WHEN** its installed state is reported
- **THEN** the response SHALL NOT include the package signature
- **AND** it SHALL NOT include the object-storage key

### Requirement: An author can confirm what their publish deployed
The dashboard CLI SHALL let an author see the version an instance has installed for
their project, without republishing and without inspecting build artifacts.

#### Scenario: Listing installed packages from the CLI
- **GIVEN** an author authenticated against an instance
- **WHEN** they ask the CLI to list that instance's dashboard packages
- **THEN** the CLI SHALL report each package's manifest id, version, route, and enabled state

#### Scenario: Comparing the local project against the instance
- **GIVEN** a dashboard project whose manifest declares a version
- **WHEN** the author asks the CLI for that project's status against an instance
- **THEN** the CLI SHALL report the locally declared version and the version the instance has installed
- **AND** it SHALL state plainly whether they differ

#### Scenario: The project is not installed on that instance
- **GIVEN** a dashboard project that has never been published to the instance being queried
- **WHEN** the author asks for its status
- **THEN** the CLI SHALL report that the instance has no such package
- **AND** it SHALL NOT present that as an error in the local project
