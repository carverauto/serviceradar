# database-bootstrap Delta

## ADDED Requirements

### Requirement: Every bootstrap path seeds the default partition
Every database bootstrap path SHALL create the `default` partition when no
partition with that slug exists. That covers a migration on an existing database
and the schema-baseline bootstrap of an empty one. Bootstrap SHALL NOT modify a
`default` partition that already exists, and a rollback SHALL NOT delete it.

#### Scenario: A fresh install from the schema baseline
- **WHEN** an empty database is bootstrapped from the schema baseline
- **THEN** the `default` partition exists and is enabled

#### Scenario: An existing install with an edited default partition
- **GIVEN** an operator renamed the `default` partition's display name
- **WHEN** migrations run
- **THEN** that row is unchanged
