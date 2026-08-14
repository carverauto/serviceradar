## MODIFIED Requirements

### Requirement: Eligible service images publish multi-arch OCI indexes

Eligible generic service images SHALL publish amd64 and arm64 variants through a single
canonical Bazel image-index target.

Eligibility SHALL be assessed over **every layer the image packages** — its base image, its
rootfs bundles, and any third-party binary — and not only over the first-party artifact. An
image SHALL be eligible when every one of those layers resolves for the target platform. An
image SHALL be ineligible when any layer is pinned to a single architecture, such as a
third-party Debian package, a downloaded prebuilt binary, or a language runtime compiled for
the host.

An ineligible image SHALL record the blocking layer, so that an amd64-only image is
distinguishable from one that has merely not been declared yet.

#### Scenario: Building a multi-arch service image
- **GIVEN** a service is marked eligible for multi-arch publishing
- **WHEN** its canonical image target is built or pushed
- **THEN** Bazel SHALL produce amd64 and arm64 image variants
- **AND** Bazel SHALL publish a single OCI image index for that service repository

#### Scenario: Existing tag behavior is preserved
- **GIVEN** a migrated service image is published
- **WHEN** the push workflow runs
- **THEN** the repository SHALL continue to receive the existing tag set such as `latest`, `sha-<commit>`, and `v<VERSION>`

#### Scenario: A first-party binary that cross-compiles does not by itself confer eligibility
- **GIVEN** an image whose service binary builds for both architectures
- **WHEN** the image also packages a base image or rootfs layer pinned to one architecture
- **THEN** the image SHALL NOT be treated as eligible
- **AND** the pinned layer SHALL be replaced with a platform-aware equivalent, or removed, before the index is declared

#### Scenario: An image packaging an architecture-pinned payload stays single-arch
- **GIVEN** an image packages a payload available only for amd64, such as a pinned Debian package or a host-compiled language runtime
- **WHEN** its image definition is reviewed for multi-arch eligibility
- **THEN** the image SHALL remain amd64-only
- **AND** the blocking layer SHALL be recorded as the reason
- **AND** the image SHALL NOT declare a multi-arch index that it cannot satisfy

#### Scenario: An eligible image is added to the publish manifest
- **GIVEN** an eligible image declares a multi-arch index target
- **WHEN** its entry in the publishable image inventory is updated
- **THEN** the entry SHALL name the index target as its push artifact
- **AND** the aggregate publish target SHALL push the index rather than the amd64 image

## ADDED Requirements

### Requirement: Image definition helpers select layers by target platform

Shared image-definition helpers SHALL resolve base images, rootfs bundles and architecture
metadata through the target-platform select, rather than naming one architecture directly.

A base-less image SHALL declare its `architecture` through that same select, because the
container rules require the attribute literally when there is no base to inherit it from and
the image-index platform transition does not supply it.

#### Scenario: A helper is used for a multi-arch image
- **WHEN** an image-definition helper resolves a base image or rootfs layer
- **THEN** it SHALL select that layer on the target platform
- **AND** it SHALL NOT name a single-architecture repository or rootfs target directly

#### Scenario: A base-less image declares its architecture
- **GIVEN** an image is built with no base image
- **WHEN** its architecture metadata is declared
- **THEN** that metadata SHALL be selected on the target platform
- **AND** a hardcoded architecture SHALL be treated as a defect, because the resulting index advertises one platform twice while carrying binaries for two

### Requirement: Multi-arch indexes are verified per architecture

A multi-arch index SHALL be verified to contain a genuinely native binary for each
architecture it advertises, not merely an index entry claiming that platform. This
verification SHALL be enforced by a build target rather than by review.

This is required because an index whose entries are mislabelled satisfies every
manifest-shape check while failing at runtime on the target it claims to support.

#### Scenario: Verifying an index
- **WHEN** a multi-arch image index is built
- **THEN** the index SHALL advertise both `linux/amd64` and `linux/arm64`
- **AND** the binaries packaged in the `linux/arm64` entry SHALL report an aarch64 ELF machine type
- **AND** the binaries packaged in the `linux/amd64` entry SHALL report an x86-64 ELF machine type

#### Scenario: A mislabelled entry fails verification
- **GIVEN** an index advertises `linux/arm64`
- **WHEN** a binary packaged in that entry reports an x86-64 ELF machine type
- **THEN** verification SHALL fail
- **AND** the failure SHALL name the image and the offending file

#### Scenario: An index advertising one platform twice fails verification
- **GIVEN** an index whose child manifests both declare the same platform
- **WHEN** verification runs
- **THEN** it SHALL fail rather than report a satisfied two-entry index
