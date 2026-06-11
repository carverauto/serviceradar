## ADDED Requirements

### Requirement: Add-ons and plugins ship alert rule bundles

Native add-ons and WASM plugins SHALL be able to ship stateful alert rule
templates as part of their package: rule templates declared in the add-on/
plugin manifest are registered by the control plane when the package is
imported/assigned, carrying provenance (source package id and version),
appearing in the rule management UI as templates the operator can enable or
customize. Package upgrades SHALL update the shipped templates without
overwriting operator-customized rule instances derived from them; package
removal SHALL mark orphaned templates rather than silently deleting active
alerting. The add-on SDK and WASM plugin SDK documentation SHALL define the
bundle convention and the requirement that bundled rules match only the
package's own documented event attributes.

#### Scenario: Bundled templates registered with provenance

- **WHEN** an add-on shipping alert rule templates is imported/assigned
- **THEN** its templates SHALL appear in rule management attributed to the
  add-on id and version
- **AND** enabling one SHALL create a normal stateful alert rule evaluated
  by the existing engine

#### Scenario: Upgrade preserves operator customization

- **GIVEN** an operator-customized rule created from a bundled template
- **WHEN** the add-on upgrades with a changed template
- **THEN** the template SHALL update and the customized rule SHALL remain
  unchanged, with the divergence visible

#### Scenario: Removal does not silently kill alerting

- **WHEN** an add-on with enabled bundled rules is removed
- **THEN** the rules SHALL be marked orphaned/disabled with an operator-
  visible notice rather than deleted without trace

#### Scenario: Edge collector ships spool-pressure alerts

- **GIVEN** the otel-collector add-on's bundled rules
- **WHEN** an edge site's spool emits sustained high-utilization or
  eviction-active OCSF events (per the spool usage reporting requirement)
- **THEN** enabling the bundled templates SHALL produce alerts that trigger
  during the pressure window and resolve on the clearing events
