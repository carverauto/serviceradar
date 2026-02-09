# release-packaging Specification

## Purpose

Every deployable ServiceRadar service produces Debian and RPM packages in the release workflow so bare-metal and VM deployments can install any service from the GitHub release artifacts.

## ADDED Requirements

### Requirement: All deployable Elixir services produce OS packages

The build system SHALL produce `.deb` and `.rpm` packages for every deployable Elixir service (core-elx, agent-gateway, web-ng).

#### Scenario: core-elx deb and rpm are in the release artifacts

- **GIVEN** the release workflow runs
- **WHEN** Bazel builds `//release:package_artifacts`
- **THEN** the output includes `serviceradar-core-elx_<version>_amd64.deb` and `serviceradar-core-elx-<version>.x86_64.rpm`

#### Scenario: agent-gateway deb and rpm are in the release artifacts

- **GIVEN** the release workflow runs
- **WHEN** Bazel builds `//release:package_artifacts`
- **THEN** the output includes `serviceradar-agent-gateway_<version>_amd64.deb` and `serviceradar-agent-gateway-<version>.x86_64.rpm`

### Requirement: Elixir service packages ship a release tarball

Each Elixir service package SHALL contain the Mix release tarball, an environment config file, a systemd unit, and install/remove scripts.

#### Scenario: core-elx package contents

- **GIVEN** `serviceradar-core-elx` is installed from the .deb
- **THEN** the following paths exist:
  - `/usr/local/share/serviceradar-core-elx/serviceradar-core-elx.tar.gz`
  - `/etc/serviceradar/core-elx.env`
  - `/lib/systemd/system/serviceradar-core-elx.service`
- **AND** `systemctl start serviceradar-core-elx` launches the Elixir release

#### Scenario: agent-gateway package contents

- **GIVEN** `serviceradar-agent-gateway` is installed from the .deb
- **THEN** the following paths exist:
  - `/usr/local/share/serviceradar-agent-gateway/serviceradar-agent-gateway.tar.gz`
  - `/etc/serviceradar/agent-gateway.env`
  - `/lib/systemd/system/serviceradar-agent-gateway.service`
- **AND** `systemctl start serviceradar-agent-gateway` launches the Elixir release

### Requirement: Environment config files are not overwritten on upgrade

Package upgrades SHALL preserve operator-modified configuration files.

#### Scenario: deb upgrade preserves env file

- **GIVEN** an operator has customized `/etc/serviceradar/core-elx.env`
- **WHEN** a newer version of `serviceradar-core-elx` is installed
- **THEN** the existing env file is preserved (dpkg conffile protection)

#### Scenario: rpm upgrade preserves env file

- **GIVEN** an operator has customized `/etc/serviceradar/core-elx.env`
- **WHEN** a newer RPM of `serviceradar-core-elx` is installed
- **THEN** the existing env file is preserved (`config(noreplace)`)

### Requirement: Package auto-discovery in release pipeline

Adding a new entry to `packaging/packages.bzl` SHALL automatically include that component in the release artifacts without modifying the release workflow or `release_targets.bzl`.

#### Scenario: New PACKAGES entry appears in release

- **GIVEN** a new key is added to the `PACKAGES` dict in `packages.bzl`
- **AND** a corresponding `packaging/<name>/BUILD.bazel` calls `serviceradar_package_from_config`
- **WHEN** Bazel builds `//release:package_artifacts`
- **THEN** the new component's .deb and .rpm are included
