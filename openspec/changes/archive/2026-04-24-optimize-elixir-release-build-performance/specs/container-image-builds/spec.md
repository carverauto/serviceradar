## ADDED Requirements
### Requirement: Elixir release build actions avoid live dependency bootstrap
Elixir release build actions used by Bazel container packaging SHALL avoid opportunistic dependency and tool bootstrap inside the release action when the required inputs can be provided explicitly by Bazel.

#### Scenario: Building an Elixir release target
- **GIVEN** a maintainer builds `//elixir/web-ng:release_tar`, `//elixir/serviceradar_core_elx:release_tar`, or `//elixir/serviceradar_agent_gateway:release_tar`
- **WHEN** the Bazel `mix_release` action executes
- **THEN** the action SHALL use predeclared dependency and tool inputs for Hex, Rebar, and other required build tooling
- **AND** the action SHALL NOT rely on live dependency bootstrap as the normal path for a successful build

#### Scenario: Rebuilding after unrelated image changes
- **GIVEN** the Elixir source inputs are unchanged
- **WHEN** unrelated non-Elixir image targets are rebuilt
- **THEN** Elixir release actions SHALL maximize cache reuse instead of repeating dependency bootstrap work inside the release action

### Requirement: Web-ng asset preparation is cacheable and explicit
The Bazel build path for `web_ng` SHALL treat asset dependency preparation and asset output generation as explicit, cacheable build inputs to release packaging.

#### Scenario: Building the web-ng release tarball
- **GIVEN** a maintainer builds `//elixir/web-ng:release_tar`
- **WHEN** the Bazel release pipeline prepares frontend assets
- **THEN** the asset dependency state and generated asset outputs SHALL be provided through explicit Bazel-managed inputs or intermediate targets
- **AND** release packaging SHALL NOT treat package installation as an implicit side effect of the final release action
