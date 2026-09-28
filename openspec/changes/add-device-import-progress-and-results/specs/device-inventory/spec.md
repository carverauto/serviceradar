## ADDED Requirements

### Requirement: A running device import is visibly in progress
While a device CSV import is running, the interface SHALL indicate that work is in
progress on the control that started it, and SHALL prevent the same import being
started again. The interface SHALL remain responsive while the import runs.

#### Scenario: The control reports that it is working
- **GIVEN** an operator who has previewed a device CSV and starts the import
- **WHEN** the import is running
- **THEN** the control that started it SHALL indicate work in progress
- **AND** it SHALL be disabled for the duration

#### Scenario: A second click does not start a second import
- **GIVEN** an import that is already running
- **WHEN** the operator activates the import control again
- **THEN** no additional import SHALL be started
- **AND** the running import SHALL be unaffected

#### Scenario: The interface does not block while importing
- **GIVEN** an import whose work takes many seconds, for example one resolving hostnames over DNS for many rows
- **WHEN** the import is running
- **THEN** the interface SHALL continue to render
- **AND** the operator SHALL NOT be left with a screen that cannot distinguish "working" from "broken"

### Requirement: A finished device import reports what it did
When a device CSV import finishes, the interface SHALL present a summary that
accounts for every row the operator submitted, and that summary SHALL persist until
the operator dismisses it.

#### Scenario: A wholly successful import is accounted for
- **GIVEN** a device CSV whose every row imports without error
- **WHEN** the import finishes
- **THEN** the operator SHALL be shown how many devices were created and how many existing devices were updated
- **AND** the summary SHALL remain visible until explicitly dismissed

#### Scenario: A partial import distinguishes what succeeded from what did not
- **GIVEN** a device CSV in which some rows import and others fail
- **WHEN** the import finishes
- **THEN** the summary SHALL report the created and updated counts alongside the failures
- **AND** it SHALL identify the failures, not merely count them

#### Scenario: Rows dropped while reading the file are reported too
- **GIVEN** a device CSV containing rows that cannot be read as a device, for example a row missing both hostname and IP
- **WHEN** the import finishes
- **THEN** the summary SHALL report those rows as skipped, with the reason each was skipped
- **AND** a skipped row SHALL NOT be presented as created or updated

#### Scenario: A summary is not discarded before it can be read
- **GIVEN** a finished import
- **WHEN** the operator has not yet dismissed the summary
- **THEN** the summary SHALL NOT be replaced, cleared, or navigated away from automatically

### Requirement: An import that fails outright says so
If the import cannot complete — because the work crashed or was terminated rather
than returning a result — the interface SHALL report a failure.

#### Scenario: A crashed import does not appear to still be running
- **GIVEN** an import whose work terminates abnormally
- **WHEN** the interface learns of the termination
- **THEN** it SHALL stop indicating progress
- **AND** it SHALL report that the import failed
- **AND** the import control SHALL become usable again so the operator can retry
