## ADDED Requirements
### Requirement: Add-On Profile Management UI
The settings UI SHALL let operators create, preview, enable, disable, and inspect native add-on profiles using SRQL target queries.

#### Scenario: Operator previews add-on profile targets
- **GIVEN** an operator is editing an add-on profile with an SRQL target query
- **WHEN** they request a preview
- **THEN** the UI SHALL show matched agents, eligible agents, skipped agents, and skip reasons before the profile is saved or enabled.

#### Scenario: Operator inspects assignment provenance
- **GIVEN** an agent has an add-on assignment produced by a profile
- **WHEN** an operator views the agent add-ons page
- **THEN** the UI SHALL show the source profile and reconcile status for that assignment.
