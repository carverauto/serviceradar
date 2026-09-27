## ADDED Requirements

### Requirement: Identity De-duplication Tasks
The system SHALL open a de-duplication task for every identity decision that blocks, declines
or overrides a merge between two or more devices, and SHALL keep exactly one task per candidate
device set for the set's whole life: a later decision about the same set SHALL update that task
and SHALL NOT open a second task or reopen a task an operator resolved or dismissed. An operator
SHALL be able to resolve an open task by merging its devices into one of them, by marking them
distinct, or by dismissing it, and the resolution, the resolving actor and the time SHALL be
recorded on the task. Marking devices distinct SHALL record a durable assertion for every pair,
and no automatic merge path SHALL merge an asserted pair. A decision about devices that are
already asserted distinct SHALL NOT open a task.

#### Scenario: A refused merge opens one task
- **GIVEN** two devices whose shared identifiers are only randomized MACs
- **WHEN** the merge policy refuses to merge them, twice
- **THEN** exactly one open de-duplication task names both devices
- **AND** its occurrence count is two

#### Scenario: Marking devices distinct stops automatic merges
- **GIVEN** an open task for two devices
- **WHEN** an operator marks them distinct
- **THEN** the task is recorded as distinct with the operator and time
- **AND** every automatic merge of the pair, including the scheduled duplicate backfill, is
  refused

#### Scenario: Merging from a task
- **GIVEN** an open task for three devices
- **WHEN** an operator merges them into one of the three
- **THEN** the other two are merged into the survivor through the administrative merge path
- **AND** the task is recorded as merged into that survivor

#### Scenario: A dismissed task stays dismissed
- **GIVEN** a task an operator dismissed
- **WHEN** the same merge is refused again
- **THEN** the task's occurrence count increases
- **AND** the task stays dismissed until an operator reopens it

#### Scenario: Only operators resolve tasks
- **WHEN** a viewer tries to merge, mark distinct or dismiss a task
- **THEN** the action is refused and no device changes

### Requirement: De-duplication Review Queue
The web UI SHALL provide a review queue at `/devices/deduplication` that lists de-duplication tasks by status, open tasks first by default, each with its device set, the kind and reason of the decision that opened it, its occurrence count and the time of its latest decision. Reviewing a task SHALL show its devices, including tombstoned ones, and the identity decisions about exactly that device set with their evidence. Any user with `devices.view` SHALL be able to read the queue; only a user allowed to resolve tasks SHALL be offered, and SHALL be able to perform, merge into a chosen survivor, mark distinct, dismiss and reopen. Every queue event SHALL re-check the user's permission, and a resolution SHALL re-read the task rather than trust the submitted form. A task resolved elsewhere SHALL leave the open queue of every session showing it without a reload.

#### Scenario: An operator resolves a task from the queue
- **GIVEN** an open task for two devices
- **WHEN** an operator reviews it, selects one device to keep and merges
- **THEN** the other device is merged into the selected one
- **AND** the task is recorded as merged into it and leaves the open queue

#### Scenario: A viewer reads the queue but cannot resolve
- **GIVEN** an open task
- **WHEN** a viewer opens the queue and submits a merge, mark distinct or dismiss event directly
- **THEN** the task and the devices are listed
- **AND** each action is refused and the task stays open

#### Scenario: A resolution in another session updates the queue
- **GIVEN** an operator viewing the open queue
- **WHEN** another operator dismisses one of the listed tasks
- **THEN** the task leaves the first operator's open queue without a reload
