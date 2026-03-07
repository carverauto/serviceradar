# container-image-builds Specification

## Purpose
Define the Bazel-native, artifact-first rules for building and publishing ServiceRadar container images.
## Requirements
### Requirement: Generic service images use artifact-first Bazel packaging
Generic ServiceRadar service images SHALL be defined from Bazel build artifacts through shared Bazel image macros instead of service-specific rootfs assembly logic.

#### Scenario: Packaging a Go or Rust service image
- **GIVEN** a service exposes a Bazel binary target and runtime metadata
- **WHEN** a maintainer defines its container image
- **THEN** the image SHALL package that Bazel artifact directly into the OCI image through the shared macro
- **AND** the image definition SHALL NOT require a service-specific rootfs `genrule`

#### Scenario: Packaging an Elixir release image
- **GIVEN** a service exposes a Bazel release tarball and runtime metadata
- **WHEN** a maintainer defines its container image
- **THEN** the image SHALL package that release artifact through the shared release-image macro
- **AND** the image definition SHALL preserve the service's declared entrypoint, environment, and working directory

### Requirement: Generic runtime bases are declarative and reusable
Generic service images SHALL consume a small set of declarative Bazel-managed runtime base profiles instead of manually extracting individual OS packages into per-image tar layers.

#### Scenario: Updating a shared runtime package set
- **GIVEN** multiple service images require the same runtime utilities
- **WHEN** that package set is updated
- **THEN** the package manifest SHALL be changed in one shared base-profile definition
- **AND** the consuming service images SHALL inherit the change without adding new package-extraction `genrule` blocks

#### Scenario: Creating a minimal runtime image
- **GIVEN** a service only needs its built artifact and a thin runtime base
- **WHEN** its image is defined
- **THEN** the image SHALL use a reusable base profile plus the service artifact layer
- **AND** no image-specific package extraction step SHALL be required

### Requirement: Eligible service images publish multi-arch OCI indexes
Eligible generic service images SHALL publish amd64 and arm64 variants through a single canonical Bazel image-index target.

#### Scenario: Building a multi-arch service image
- **GIVEN** a service is marked eligible for multi-arch publishing
- **WHEN** its canonical image target is built or pushed
- **THEN** Bazel SHALL produce amd64 and arm64 image variants
- **AND** Bazel SHALL publish a single OCI image index for that service repository

#### Scenario: Existing tag behavior is preserved
- **GIVEN** a migrated service image is published
- **WHEN** the push workflow runs
- **THEN** the repository SHALL continue to receive the existing tag set such as `latest`, `sha-<commit>`, and `v<VERSION>`

### Requirement: Generic image builds are remote-execution-safe
Generic service image builds SHALL run correctly on Linux remote execution without depending on host-specific wrapper targets, ambiguous image references, or host tool selection.

#### Scenario: Building a Bazel-native Elixir release remotely
- **GIVEN** an Elixir service release target is built on Linux remote execution
- **WHEN** the release rule runs
- **THEN** it SHALL compile the application before running asset deployment
- **AND** the release tarball SHALL build without relying on a shell-wrapper image path

#### Scenario: Resolving a base image remotely
- **GIVEN** a generic service image pulls a remote OCI base
- **WHEN** Bazel resolves that base image for a remote Linux build
- **THEN** the image reference SHALL be fully qualified with its registry host
- **AND** the build SHALL use Linux platform and toolchain resolution rather than host-specific tool selection

### Requirement: Exceptional image builds are isolated and documented
Image builds that compile or overlay database extensions or other complex OS-level payloads SHALL remain on dedicated build paths and SHALL NOT define the generic service-image pattern.

#### Scenario: CNPG remains an explicit exception
- **GIVEN** the CNPG image build compiles and installs TimescaleDB, AGE, and PostGIS-related payloads
- **WHEN** the generic service-image refactor is applied
- **THEN** the CNPG image SHALL remain on a dedicated build path
- **AND** the generic service-image macros SHALL not depend on CNPG-specific extraction or extension-build helpers
