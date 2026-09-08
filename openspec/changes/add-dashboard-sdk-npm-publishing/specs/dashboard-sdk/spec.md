## ADDED Requirements

### Requirement: npm-installable dashboard SDK package
The dashboard SDK SHALL be published as `@serviceradar/dashboard-sdk` with package metadata and npm publish configuration suitable for public installation by customer dashboard repositories.

#### Scenario: Customer installs the SDK from npm
- **GIVEN** a customer dashboard package depends on `@serviceradar/dashboard-sdk`
- **WHEN** the developer runs `npm install`
- **THEN** npm SHALL resolve the SDK without a local file path
- **AND** the installed package SHALL include the SDK source modules, type declarations, Go helpers, and dashboard package tooling needed for development.

#### Scenario: Package dry-run validates intended files
- **GIVEN** an SDK maintainer changes package contents
- **WHEN** CI runs package validation
- **THEN** `npm pack --dry-run` SHALL complete successfully
- **AND** the package manifest SHALL include only intended publishable files.

### Requirement: dashboard SDK CI gate
The dashboard SDK repository SHALL run an automated CI gate for pull requests and pushes that installs locked dependencies, executes SDK tests, and validates the npm package contents.

#### Scenario: Pull request validates SDK package
- **GIVEN** a pull request modifies the dashboard SDK
- **WHEN** the CI workflow runs
- **THEN** it SHALL install dependencies from `package-lock.json`
- **AND** it SHALL run JavaScript and Go SDK tests
- **AND** it SHALL run npm package dry-run validation before reporting success.

### Requirement: guarded npm publishing workflow
The dashboard SDK repository SHALL provide an npm publish workflow that publishes only intentional release versions and uses repository secrets for npm authentication.

#### Scenario: Tagged release publishes to npm
- **GIVEN** an SDK release tag matches `v<package.json version>`
- **AND** the repository has an `NPM_TOKEN` secret configured
- **WHEN** the npm publish workflow runs
- **THEN** it SHALL run the CI validation steps
- **AND** it SHALL publish `@serviceradar/dashboard-sdk` to npm with public access
- **AND** it SHALL NOT print the npm token in logs.

#### Scenario: Version mismatch blocks publish
- **GIVEN** an SDK release tag does not match `v<package.json version>`
- **WHEN** the npm publish workflow runs
- **THEN** it SHALL fail before publishing
- **AND** it SHALL report the expected tag derived from `package.json`.
