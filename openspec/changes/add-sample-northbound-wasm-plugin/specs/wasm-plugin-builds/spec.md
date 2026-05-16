## ADDED Requirements

### Requirement: Sample Northbound Wasm Plugin Bundle

The repository SHALL build a first-party sample northbound Wasm plugin bundle through the existing Bazel Wasm plugin pipeline.

#### Scenario: Build sample northbound bundle

- **GIVEN** the sample northbound plugin source, manifest, and config schema exist
- **WHEN** the Bazel Wasm plugin build target runs
- **THEN** Bazel compiles the Go/TinyGo plugin to Wasm
- **AND** assembles a canonical plugin bundle containing `plugin.yaml`, `plugin.wasm`, and `config.schema.json`

#### Scenario: Publish sample northbound artifact

- **GIVEN** first-party Wasm plugin artifacts are published for a release
- **WHEN** the publish workflow processes the sample northbound plugin bundle
- **THEN** Harbor receives an OCI artifact for the sample plugin
- **AND** the artifact uses the same immutable tag and signature policy as other first-party Wasm plugins
