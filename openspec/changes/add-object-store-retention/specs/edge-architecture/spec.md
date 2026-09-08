## ADDED Requirements
### Requirement: Mirrored Agent Release Artifacts Are Retained By Policy
The control plane SHALL clean up mirrored agent release artifacts from internal object storage according to a configurable, reference-aware retention policy. By default, the policy SHALL retain artifacts for the newest 5 published releases and SHALL protect any release artifacts referenced by active or non-terminal rollout state.

#### Scenario: Old unreferenced release artifacts are removed
- **GIVEN** more than 5 published agent releases have mirrored artifacts in internal object storage
- **AND** an older release is not referenced by an active rollout, rollout target, or rollback/current-version path
- **WHEN** the object retention worker runs in destructive mode
- **THEN** the worker deletes the older release's mirrored objects
- **AND** keeps the newest 5 releases' mirrored objects

#### Scenario: Referenced release artifacts are protected
- **GIVEN** an older agent release has mirrored artifacts in internal object storage
- **AND** an active rollout target still references that release
- **WHEN** the object retention worker runs
- **THEN** the worker does not delete the referenced release artifacts
- **AND** reports them as protected in the cleanup summary
