## ADDED Requirements
### Requirement: First-party plugin publication artifacts match the bundle contract
First-party Wasm plugins published by the repository SHALL use the same bundle contract accepted by the plugin import system rather than publishing a naked Wasm binary alone.

#### Scenario: Published artifact contains importable bundle contents
- **GIVEN** a first-party Wasm plugin published to Harbor
- **WHEN** the artifact payload is fetched
- **THEN** it SHALL contain the plugin manifest and Wasm binary
- **AND** it MAY contain optional sidecar files such as config schema or display contract

#### Scenario: Published artifact remains compatible with import validation
- **GIVEN** a first-party Wasm plugin bundle published from the repository
- **WHEN** the bundle is later submitted to the control-plane import flow
- **THEN** the same manifest and sidecar validation rules SHALL apply
- **AND** no alternate first-party-only package format SHALL be required
