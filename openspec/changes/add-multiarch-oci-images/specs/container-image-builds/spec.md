## MODIFIED Requirements

### Requirement: Eligible service images publish multi-arch OCI indexes

Eligible generic service images SHALL publish amd64 and arm64 variants through a single
canonical Bazel image-index target.

An image SHALL be eligible when every artifact it packages is produced by a Bazel
toolchain that resolves for the target platform — currently Go and Rust binaries built
through the hermetic cc toolchain, where libc is a target-platform property. An image
SHALL be ineligible when it packages a payload pinned to a single architecture, such as a
third-party Debian package, a downloaded prebuilt binary, or a language runtime compiled
for the host.

An ineligible image SHALL record the blocking payload, so that an amd64-only image is
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

#### Scenario: An image packaging an architecture-pinned payload stays single-arch
- **GIVEN** an image packages a payload available only for amd64, such as a pinned Debian package or a host-compiled language runtime
- **WHEN** its image definition is reviewed for multi-arch eligibility
- **THEN** the image SHALL remain amd64-only
- **AND** the blocking payload SHALL be recorded as the reason
- **AND** the image SHALL NOT declare a multi-arch index that it cannot satisfy

#### Scenario: An eligible image is added to the publish manifest
- **GIVEN** an eligible image declares a multi-arch index target
- **WHEN** its entry in the publishable image inventory is updated
- **THEN** the entry SHALL name the index target as its push artifact
- **AND** the aggregate publish target SHALL push the index rather than the amd64 image

## ADDED Requirements

### Requirement: Multi-arch indexes are verified per architecture

A published multi-arch index SHALL be verified to contain a genuinely native binary for
each architecture it advertises, not merely an index entry claiming that platform.

This is required because an index whose entries both hold amd64 binaries satisfies every
manifest-shape check while failing at runtime on the target it claims to support.

#### Scenario: Verifying a published index
- **WHEN** a multi-arch image index is published
- **THEN** the index manifest SHALL list both `linux/amd64` and `linux/arm64`
- **AND** the binary extracted from the `linux/arm64` entry SHALL report an aarch64 machine type
- **AND** the binary extracted from the `linux/amd64` entry SHALL report an x86-64 machine type

#### Scenario: A mislabelled entry fails verification
- **GIVEN** an index advertises `linux/arm64`
- **WHEN** the binary in that entry reports an x86-64 machine type
- **THEN** verification SHALL fail
- **AND** the index SHALL NOT be treated as multi-arch
