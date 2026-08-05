## ADDED Requirements

### Requirement: k8s-inventory service image packaging
The build system SHALL package `serviceradar-k8s-inventory` as a first-party ServiceRadar container image using the same artifact-first / multi-arch patterns applied to other optional collector services, so Helm can reference it via chart image tags.

#### Scenario: Image is buildable for chart consumption
- **WHEN** the release or CI image pipeline builds collector images
- **THEN** a `serviceradar-k8s-inventory` image artifact is produced and taggable like other ServiceRadar services

#### Scenario: Image is optional at deploy time
- **WHEN** Helm `k8sInventory.enabled` is false
- **THEN** cluster installs MUST NOT require the inventory image to be present for a successful deploy of other components
