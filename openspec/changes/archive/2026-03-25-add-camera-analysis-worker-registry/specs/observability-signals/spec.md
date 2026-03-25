## ADDED Requirements
### Requirement: Worker selection remains observable
The system SHALL emit observable worker identity and selection outcomes for relay-scoped camera analysis dispatch.

#### Scenario: A registered worker is selected successfully
- **GIVEN** a relay-scoped analysis branch with a resolvable worker target
- **WHEN** the platform dispatches work to that worker
- **THEN** observability signals SHALL preserve the selected worker identity
- **AND** SHALL preserve the originating relay session and branch identity

#### Scenario: Worker selection fails
- **GIVEN** a relay-scoped analysis branch that requests an unavailable or unmatched worker
- **WHEN** the platform cannot resolve a valid worker
- **THEN** the platform SHALL emit an explicit bounded failure signal
- **AND** SHALL preserve the originating relay session and branch identity in that signal
