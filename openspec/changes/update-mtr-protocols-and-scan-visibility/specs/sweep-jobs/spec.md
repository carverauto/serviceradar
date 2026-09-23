## ADDED Requirements

### Requirement: MTR Jobs In Active Scans
The Network Sweeps Active Scans view SHALL list running and recent MTR bulk jobs alongside sweep executions, in a shared row shape with a filter for sweeps, MTR, or all, visible only to users holding the MTR diagnostics view permission.

#### Scenario: Running MTR job appears
- **GIVEN** an MTR bulk job has been dispatched and not yet reached a terminal state
- **WHEN** an authorized user opens the Active Scans tab
- **THEN** the job appears as a running scan with its profile name (or "Manual"), agent, protocol set, elapsed time, and target progress
- **AND** progress updates from the agent command stream update the row without a page reload

#### Scenario: Completed MTR job appears in recent scans
- **WHEN** an MTR bulk job completes, fails, expires, or is canceled
- **THEN** it appears in recent scans with status, start time, duration, completed/failed/timed-out target counts, and the number of targets reached
- **AND** the row links to that job on the MTR diagnostics page

#### Scenario: Filter by scan kind
- **WHEN** the user selects the MTR filter
- **THEN** only MTR bulk jobs are listed, and selecting Sweeps or All restores the other rows

#### Scenario: User without MTR permission
- **WHEN** a user without the MTR diagnostics view permission opens the Active Scans tab
- **THEN** no MTR rows, counts, or filter are shown
- **AND** sweep execution rows render exactly as before
