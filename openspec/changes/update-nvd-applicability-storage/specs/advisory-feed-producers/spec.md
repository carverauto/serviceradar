## MODIFIED Requirements

### Requirement: NVD Applicability Expressions Are Preserved And Evaluated

The system SHALL normalize complete NVD applicability expressions alongside
indexed affected coordinates. It SHALL preserve nested AND/OR nodes, negation,
configuration and node identity, version predicates, and the role of every CPE
term. The matcher SHALL evaluate the normalized expression and SHALL NOT parse
the raw NVD JSON object at match time. Each normalized configuration expression
SHALL be stored once per advisory, and affected coordinates SHALL reference it
rather than embed it, so the bytes stored for one advisory grow linearly with
its coordinate count plus its configuration size.

#### Scenario: Application and required operating system both match

- **GIVEN** an NVD alternative requires an affected application CPE and a specific operating-system CPE
- **AND** the installed package and known endpoint operating system satisfy both terms
- **WHEN** endpoint vulnerability matching runs
- **THEN** the affected application coordinate SHALL be eligible for applicability adjudication
- **AND** the complete satisfied alternative SHALL be retained in match evidence

#### Scenario: RHEL-only condition is evaluated on Ubuntu

- **GIVEN** an NVD alternative requires an affected application and a RHEL environmental CPE
- **AND** the installed package has evidence-backed Ubuntu release identity
- **WHEN** endpoint vulnerability matching runs
- **THEN** that NVD alternative SHALL evaluate false
- **AND** it SHALL NOT confirm the Ubuntu package as affected

#### Scenario: Required environment fact is unavailable

- **GIVEN** an NVD alternative requires an environment fact that endpoint inventory does not know
- **WHEN** endpoint vulnerability matching runs
- **THEN** the expression SHALL evaluate unknown rather than true or false
- **AND** the NVD evidence SHALL produce at most a candidate with the unknown term recorded

#### Scenario: Environmental CPE term is not emitted as affected product

- **GIVEN** an NVD configuration contains a `vulnerable:false` CPE term as an environmental requirement
- **WHEN** the record is normalized
- **THEN** the term SHALL remain in the applicability expression with its environmental role
- **AND** it SHALL NOT be emitted as an independently affected coordinate

#### Scenario: Explicit CPE version without range bounds is exact

- **GIVEN** an affected NVD CPE term contains an explicit product version and no separate start or end bounds
- **WHEN** the matcher compares an installed package with a different normalized upstream version
- **THEN** that CPE term SHALL evaluate false for the installed package
- **AND** only the identical version SHALL satisfy the term unless the CPE explicitly uses an any-version value

#### Scenario: Expression generation swaps atomically

- **GIVEN** a new complete NVD feed generation has normalized coordinates and applicability expressions
- **WHEN** the generation is promoted
- **THEN** its coordinates and expressions SHALL become visible atomically
- **AND** the matcher SHALL NOT observe coordinates without their corresponding expression metadata

#### Scenario: Configuration shared by many coordinates is stored once

- **GIVEN** an NVD record whose configuration lists many affected application CPEs
- **WHEN** the record is normalized and loaded
- **THEN** the advisory SHALL store that configuration expression once
- **AND** each affected coordinate SHALL store only a reference to the configuration and the term it requires
- **AND** the matcher SHALL resolve the reference to the same expression and evaluation result an embedded copy would produce

#### Scenario: Coordinates written before the reference shape remain evaluable

- **GIVEN** stored NVD coordinates still embed their configuration expression from an earlier normalization version
- **WHEN** endpoint vulnerability matching runs before the next NVD feed run rewrites them
- **THEN** the matcher SHALL evaluate the embedded expression unchanged
- **AND** the next NVD feed run SHALL rewrite those advisories into the reference shape
