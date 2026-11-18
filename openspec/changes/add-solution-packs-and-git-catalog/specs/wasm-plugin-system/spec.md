## ADDED Requirements

### Requirement: Solution Pack Plugin Dependency Verification
When a Solution Pack `manifest.json` declares `plugin_dependencies`, the system MUST verify each referenced Wasm plugin `package_id` and SemVer `version_constraint` against `ServiceRadar.Plugins.PluginPackage` approval state before activating dependent resources, and MUST NOT bypass staged capability review or auto-approve unapproved Wasm plugin packages.

#### Scenario: Approved plugin dependency satisfies pack installation
- **GIVEN** a Solution Pack declaring `plugin_dependencies` entry `io.example.wireless-controller` with constraint `>= 0.2.0 and < 1.0.0`
- **AND** `ServiceRadar.Plugins.PluginPackage` contains an `:approved` package `io.example.wireless-controller` at version `0.2.1`
- **WHEN** an operator runs the Guided Install Wizard for the pack
- **THEN** the dependency check passes and dependent checks are eligible for active installation

#### Scenario: Staged or missing plugin dependency blocks silent capability approval
- **GIVEN** a Solution Pack declaring a required `plugin_dependencies` entry whose `PluginPackage` is missing or in `:staged` status awaiting capability review
- **WHEN** an operator attempts to activate the pack
- **THEN** the system does not auto-approve the `:staged` Wasm plugin package
- **AND** the wizard surfaces the missing or `:staged` dependency with a link to Settings -> Agents -> Plugins for capability review under `plugins.approve`

### Requirement: Shared UploadSignature Verification Contract Across Plugins and Solution Packs
The ed25519 `UploadSignature` verification primitive (`ServiceRadarWebNG.Plugins.UploadSignature`) MUST enforce identical canonical JSON serialization (`{"content_hash": "<sha256>", "manifest": <canonical-manifest>}`) and per-repository key isolation across both `:wasm_plugin` bundles and `:release_catalog` `.srpack` Solution Pack archives.

#### Scenario: Canonical JSON signature conformance holds across Elixir verifier, Go signer, and CLI pack signer
- **GIVEN** a fixed conformance test manifest, archive SHA-256 `content_hash`, and test ed25519 keypair
- **WHEN** the signature payload is produced by `serviceradar pack sign` (`js/cli`), `build/wasm_plugins/upload_signature_tool.go`, and `ServiceRadarWebNG.Plugins.UploadSignature.verification_payload/2`
- **THEN** all three produce identical canonical JSON bytes and mutually verifiable ed25519 signatures
