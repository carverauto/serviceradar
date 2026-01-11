## ADDED Requirements
### Requirement: Bazel builds Phoenix release for web-ng
The build system SHALL provide a Bazel target that runs `mix assets.build` and `mix release` for `web-ng` using pinned Erlang/Elixir/Node toolchains with no host dependencies.

#### Scenario: Release tarball produced via Bazel
- **GIVEN** a clean checkout with no system Elixir/Node installed
- **WHEN** `bazel build --config=remote //web-ng:release_tar` runs
- **THEN** the build succeeds and produces a tarball containing the Phoenix release (including `bin/serviceradar_web_ng` and compiled `priv/static` assets) versioned from `VERSION`.

#### Scenario: Hermetic toolchains on RBE
- **GIVEN** RBE execution with only Bazel-provided toolchains
- **WHEN** the release target builds
- **THEN** it completes without fetching host tooling and reuses pinned OTP/Elixir/Node versions declared in the repository.

### Requirement: Bazel builds OCI image for web-ng
The build system SHALL expose an OCI image target for the web-ng release that can be loaded and run directly.

#### Scenario: OCI image builds and boots
- **GIVEN** `bazel build //docker/images:web_ng_image_amd64` and `bazel run //docker/images:web_ng_image_amd64.load`
- **WHEN** the resulting image is started with runtime env vars (`PHX_SERVER=true`, DB creds, `SECRET_KEY_BASE`)
- **THEN** the Phoenix endpoint boots and responds 200 on its health check within a bounded startup time.

#### Scenario: Image metadata aligns with release
- **GIVEN** the image build
- **WHEN** inspecting OCI labels
- **THEN** it includes `org.opencontainers.image.title=serviceradar-web-ng` and build-info JSON with commit sha/tag matching the repo state.

### Requirement: Bazel builds RPM and DEB packages for web-ng
The build system SHALL produce RPM and DEB artifacts that install the Phoenix release, config, and systemd unit using existing packaging conventions.

#### Scenario: DEB/RPM artifacts install correctly
- **GIVEN** `bazel build //packaging/web-ng:web_ng_deb //packaging/web-ng:web_ng_rpm`
- **WHEN** installing the outputs on Debian and RHEL-based containers
- **THEN** files land under `/usr/local/share/serviceradar-web-ng`, config under `/etc/serviceradar`, and systemd unit `serviceradar-web-ng.service` is enabled/available.

#### Scenario: Package versions match repo VERSION
- **GIVEN** the current `VERSION` file
- **WHEN** building packages
- **THEN** the package names and metadata reflect that version (e.g., `serviceradar-web-ng_<VERSION>_amd64.deb`).

### Requirement: web-ng artifacts are integrated into push/release workflows
The release pipeline SHALL publish web-ng OCI images (and build the DEB/RPM) alongside existing components when push workflows run.

#### Scenario: push_all includes web-ng image
- **GIVEN** `bazel run //docker/images:push_all` (or equivalent Make target)
- **WHEN** it completes
- **THEN** it pushes the `serviceradar-web-ng` image tags (`latest`, `sha-<commit>`), and CI builds/stores the DEB/RPM artifacts without breaking legacy `serviceradar-web` outputs.
