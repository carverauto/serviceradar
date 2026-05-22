## ADDED Requirements

### Requirement: Authored SRQL dashboards
The system SHALL let authorized users create saved dashboards composed of one or more SRQL-backed panels without requiring an external dashboard package or custom JavaScript artifact.

#### Scenario: User creates a dashboard from a query
- **GIVEN** an authorized user opens the dashboard creator
- **WHEN** they enter a valid SRQL query and save a dashboard with one panel
- **THEN** the system SHALL persist the dashboard definition and panel configuration
- **AND** the dashboard SHALL be retrievable by a stable dashboard identifier.

#### Scenario: Dashboard packages remain separate
- **GIVEN** an administrator has imported a trusted dashboard package
- **WHEN** a user creates an authored SRQL dashboard
- **THEN** the authored dashboard SHALL NOT create or mutate a `DashboardPackage`
- **AND** the package-host route `/dashboards/:route_slug` SHALL continue to load package dashboards.

### Requirement: Bounded SRQL preview and field inference
The system SHALL provide a bounded SRQL preview for dashboard authoring that executes the query with enforced limits and returns field metadata used to configure compatible visuals.

#### Scenario: Preview returns field metadata
- **GIVEN** a user enters `in:cpu_metrics time:last_1h limit:100`
- **WHEN** they run preview
- **THEN** the system SHALL return sample rows
- **AND** it SHALL classify returned fields by name and type hints such as temporal, numeric, categorical, boolean, or object.

#### Scenario: Invalid query blocks save
- **GIVEN** a user enters invalid SRQL
- **WHEN** they run preview or attempt to save the panel
- **THEN** the system SHALL show the SRQL validation error
- **AND** the invalid panel SHALL NOT be saved.

#### Scenario: Preview enforces safe limits
- **GIVEN** a user enters a query without a limit or with an excessive limit
- **WHEN** the preview runs
- **THEN** the system SHALL apply the configured preview limit
- **AND** it SHALL indicate that preview rows were bounded.

### Requirement: Visual compatibility selection
The dashboard creator SHALL enable only visual types compatible with the inferred SRQL result fields, while always allowing a table fallback for renderable result rows.

#### Scenario: Time-series visual is available
- **GIVEN** preview metadata includes a temporal field and at least one numeric field
- **WHEN** the visual picker renders
- **THEN** line or area time-series visuals SHALL be selectable
- **AND** the user SHALL be able to choose the time and value fields.

#### Scenario: Incompatible visual is disabled
- **GIVEN** preview metadata contains only categorical text fields
- **WHEN** the visual picker renders
- **THEN** numeric time-series visuals SHALL be disabled with an explanation
- **AND** table rendering SHALL remain available.

### Requirement: Saved dashboard routes
The system SHALL expose saved authored dashboards at `/dashboard/:dashboard_id` while preserving the existing `/dashboard` operations landing page and `/dashboards/:route_slug` package dashboard host.

#### Scenario: Saved dashboard loads by ID
- **GIVEN** a saved authored dashboard exists with ID `31337`
- **WHEN** a user opens `/dashboard/31337`
- **THEN** the system SHALL render the saved dashboard if the user is authorized to view it.

#### Scenario: Existing landing page is preserved
- **WHEN** a user opens `/dashboard`
- **THEN** the existing operations dashboard SHALL render
- **AND** the request SHALL NOT be interpreted as a saved authored dashboard.

### Requirement: Dashboard editor and library
The web UI SHALL provide an Analytics dashboard workspace where users can list, create, edit, archive/delete, and open authored dashboards.

#### Scenario: Dashboard library lists authored dashboards
- **GIVEN** the user has access to saved authored dashboards
- **WHEN** they open the Analytics dashboard workspace
- **THEN** the UI SHALL list dashboards with title, owner, visibility, updated time, and report schedule status.

#### Scenario: User edits dashboard layout
- **GIVEN** a saved dashboard has multiple panels
- **WHEN** the user edits panel order or layout and saves
- **THEN** the dashboard SHALL preserve the new layout
- **AND** the saved dashboard route SHALL render panels in that layout.

### Requirement: Dashboard report schedules
The system SHALL let authorized users configure scheduled email reports for authored dashboards using persisted report schedules.

#### Scenario: User creates a report schedule
- **GIVEN** a user can edit a dashboard
- **WHEN** they configure recipients, timezone, cadence, and enable the schedule
- **THEN** the system SHALL persist the report schedule
- **AND** it SHALL compute the next due delivery time.

#### Scenario: Disabled schedule is not delivered
- **GIVEN** a report schedule is disabled
- **WHEN** the scheduler scans for due reports
- **THEN** it SHALL NOT enqueue a delivery for the disabled schedule.

### Requirement: Bounded report scheduling jobs
The system SHALL use one periodic scanner job to find due dashboard report schedules and enqueue idempotent per-due delivery jobs, rather than registering one persistent cron/AshOban job per report schedule.

#### Scenario: Scanner enqueues due deliveries
- **GIVEN** multiple enabled report schedules are due
- **WHEN** the dashboard report scanner job runs
- **THEN** it SHALL enqueue one delivery job per due schedule occurrence
- **AND** each job SHALL be unique by schedule and due time.

#### Scenario: Scanner does not duplicate deliveries
- **GIVEN** a delivery job already exists for a schedule and due time
- **WHEN** the scanner runs again
- **THEN** it SHALL NOT enqueue a duplicate delivery.

### Requirement: Report delivery history
The system SHALL persist report delivery attempts with success/failure state, timestamps, and operator-visible error information.

#### Scenario: Successful report is recorded
- **GIVEN** a due report delivery sends successfully
- **WHEN** the delivery worker completes
- **THEN** the delivery history SHALL record success, sent timestamp, recipient count, and schedule ID.

#### Scenario: Failed report is visible
- **GIVEN** a report delivery fails during SRQL execution or email sending
- **WHEN** the delivery worker records the failure
- **THEN** the schedule detail UI SHALL show the failure reason
- **AND** the delivery history SHALL retain the failed attempt.

### Requirement: Authored dashboard authorization
The system SHALL authorize authored dashboard view, edit, delete, sharing, and report schedule actions using ServiceRadar roles/permissions.

#### Scenario: Viewer cannot edit
- **GIVEN** a user has view-only access to a dashboard
- **WHEN** they open the saved dashboard
- **THEN** they SHALL be able to view panels
- **AND** edit, delete, share, and report schedule controls SHALL be unavailable.

#### Scenario: Unauthorized route is denied
- **GIVEN** a dashboard exists but the current user is not authorized to view it
- **WHEN** they open `/dashboard/:dashboard_id`
- **THEN** the system SHALL deny access without revealing editable dashboard details.
