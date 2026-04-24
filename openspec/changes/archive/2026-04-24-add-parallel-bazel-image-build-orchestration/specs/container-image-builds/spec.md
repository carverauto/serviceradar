## ADDED Requirements
### Requirement: Container image workflows expose canonical aggregate Bazel targets
ServiceRadar SHALL expose root-level Bazel targets for building and publishing the current container-image set without relying on shell-composed target lists.

#### Scenario: Building all publishable images
- **GIVEN** a maintainer needs the full publishable image set built
- **WHEN** they run `bazel build //:images`
- **THEN** Bazel SHALL build every canonical image artifact in the current publish manifest
- **AND** the aggregate SHALL include multi-arch `oci_image_index` targets for images whose canonical publish artifact is an image index
- **AND** the aggregate SHALL be declared in Bazel rather than assembled by `make` from a `bazel query`

#### Scenario: Publishing all images
- **GIVEN** a maintainer needs to publish the full image set
- **WHEN** they run `bazel run //:push`
- **THEN** the target SHALL delegate to the canonical per-image push targets defined by the same publish manifest used for `//:images`
- **AND** the publish workflow SHALL preserve the current repository and tag behavior
- **AND** the aggregate publish target SHALL continue to support parallel execution

### Requirement: Publishable image inventory is declared once
The repo SHALL define the publishable image inventory in one Bazel-managed manifest consumed by both aggregate build and aggregate publish orchestration.

#### Scenario: Adding a new publishable image
- **GIVEN** a maintainer adds a new image that should participate in the standard publish workflow
- **WHEN** they update the shared image inventory
- **THEN** the image SHALL be included in the aggregate build target and the aggregate publish target
- **AND** the maintainer SHALL NOT need to duplicate the target list in Makefile shell logic or a separate root-level manifest
