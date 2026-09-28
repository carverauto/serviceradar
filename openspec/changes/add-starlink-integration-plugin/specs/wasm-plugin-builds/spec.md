## ADDED Requirements

### Requirement: Direct Fetching Of Project Go Modules
Every build path for Go WASM plugins (Bazel, CI workflows, the `plugin-go` CLI template and
documented local commands) SHALL resolve `github.com/carverauto/*` modules directly from
their source repositories using `GOPRIVATE` and `GONOSUMDB`, and first-party plugins SHALL
commit a `vendor/` tree so bundle builds do not require module downloads.

#### Scenario: Public proxy unavailable
- **WHEN** a plugin build runs where the public Go module proxy does not serve the SDK
- **THEN** module resolution for `github.com/carverauto/*` bypasses the public proxy and checksum database and the build succeeds

#### Scenario: Hermetic bundle build
- **WHEN** a first-party plugin bundle is built in Bazel
- **THEN** the build uses the committed `vendor/` tree and performs no module download
