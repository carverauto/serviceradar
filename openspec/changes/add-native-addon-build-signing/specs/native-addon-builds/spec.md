## ADDED Requirements

### Requirement: Native add-on manifest schema validation
The build SHALL validate each `addon.yaml` against a published manifest JSON-Schema
before assembling a bundle, and SHALL fail closed on a manifest that is missing
required fields or declares an unknown `delivery`/`supervision`/`kind` value.

#### Scenario: Valid manifest passes the gate
- **GIVEN** an `addon.yaml` with all required fields and known enum values
- **WHEN** the manifest validation gate runs
- **THEN** validation SHALL pass
- **AND** the build SHALL proceed to bundling

#### Scenario: Invalid manifest fails the build closed
- **GIVEN** an `addon.yaml` missing a required field or with an unknown `delivery` value
- **WHEN** the manifest validation gate runs
- **THEN** validation SHALL fail
- **AND** the build SHALL NOT produce a bundle for that add-on

### Requirement: Add-on dependency isolation CI enforcement
CI SHALL assert that the base `serviceradar-agent` binary's transitive Go package set
does not include any add-on implementation package, so an add-on can never be linked
into the base agent. The assertion SHALL run on every change and fail with the
offending import path when violated.

#### Scenario: Base agent stays isolated
- **WHEN** the dependency-isolation gate computes the base agent's transitive packages
- **THEN** no add-on implementation package SHALL appear in the set
- **AND** the gate SHALL pass

#### Scenario: An add-on import into the base agent is rejected
- **GIVEN** a change that adds an import of an add-on implementation package into the base agent
- **WHEN** the dependency-isolation gate runs
- **THEN** the gate SHALL fail
- **AND** SHALL report the offending package path
