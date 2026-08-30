## ADDED Requirements

### Requirement: Authenticated timezone profile control

The web UI SHALL expose the current user's timezone preference on the existing authenticated profile settings page and settings catalog shell. The control SHALL retain `Etc/UTC` and the current saved value, capability-filter the server's profile catalog to identifiers the current browser can format, and submit through the dedicated scoped self-service timezone action.

#### Scenario: User changes the profile timezone

- **GIVEN** an authenticated user on `/settings/profile`
- **WHEN** the user selects `America/Chicago` and saves the profile form
- **THEN** the page SHALL confirm the update
- **AND** subsequent timestamp rendering on the current page SHALL use `America/Chicago`

#### Scenario: Profile control shows a validation error

- **GIVEN** an authenticated user on `/settings/profile`
- **WHEN** the submitted timezone is unsupported or malformed
- **THEN** the page SHALL render a field-level error
- **AND** SHALL retain the user's previously saved preference

#### Scenario: Browser capability filtering preserves a usable choice

- **GIVEN** the server profile catalog contains a timezone the current browser cannot format
- **WHEN** the profile control prepares its choices
- **THEN** it SHALL omit that unsupported choice
- **AND** SHALL preserve `Etc/UTC` and the current saved value even when `Intl.supportedValuesOf` is unavailable

#### Scenario: Profile control survives settings chrome migration

- **GIVEN** the profile page is rendered through the current settings catalog shell or either settings chrome mode introduced by the active navigation migration
- **WHEN** an authenticated user opens `/settings/profile`
- **THEN** the timezone control SHALL remain visible and functional
- **AND** SHALL use the same dedicated self-service action in every chrome mode

### Requirement: Shared user-timezone timestamp rendering

The interactive web UI SHALL render every human-visible absolute timestamp through a shared presentation contract using the authenticated user's saved timezone. The contract SHALL retain the canonical UTC ISO-8601 instant as machine-readable and accessible metadata, SHALL use the saved IANA identifier explicitly instead of the browser's implicit local timezone, and SHALL fall back to a visible UTC representation if localization cannot be performed.

This requirement applies to interactive HTML and JavaScript-rendered charts. It SHALL NOT localize storage, telemetry payloads, SRQL/query semantics, URL or event bounds, REST/JSON responses, CSV or other downloadable exports, notification/report delivery, or schedule evaluation.

#### Scenario: Absolute timestamp renders in the selected timezone

- **GIVEN** a user whose saved timezone is `America/Chicago`
- **AND** a canonical instant of `2026-08-30T18:00:00Z`
- **WHEN** an interactive web view renders that instant
- **THEN** the visible value SHALL represent the same instant in `America/Chicago`
- **AND** the renderer SHALL retain `2026-08-30T18:00:00Z` as its canonical machine-readable value

#### Scenario: Daylight-saving rules are applied

- **GIVEN** a user whose saved timezone observes daylight-saving transitions
- **WHEN** the UI renders instants on both sides of a transition, including the repeated autumn hour
- **THEN** each full visible wall-clock value SHALL include an unambiguous numeric offset that follows the browser's IANA rules for that timezone
- **AND** both values SHALL still identify their original UTC instants

#### Scenario: Browser localization fails safely

- **GIVEN** an invalid instant, an unavailable saved timezone, or a browser without the required `Intl` support
- **WHEN** the shared renderer cannot localize the value
- **THEN** the UI SHALL retain a deterministic UTC fallback
- **AND** SHALL NOT render a blank value or silently substitute the browser's implicit timezone

#### Scenario: All interactive surfaces use the shared contract

- **GIVEN** a human-visible absolute timestamp on a dashboard, inventory/device, topology, observability, NetFlow, admin, audit, or settings surface
- **WHEN** the authenticated web UI renders the timestamp
- **THEN** it SHALL use the shared user-timezone contract
- **AND** any fixed-UTC exception SHALL be documented and visibly identified as UTC

#### Scenario: Canonical time values remain unchanged

- **GIVEN** a localized timestamp is used by a view that also filters, pivots, exports, or selects a chart range
- **WHEN** the view performs the machine-facing operation
- **THEN** it SHALL use the original canonical UTC instant rather than parsing the localized label

#### Scenario: Another open tab receives the preference after reload

- **GIVEN** a user has multiple already-open browser tabs
- **WHEN** the user changes the timezone in one tab
- **THEN** that tab SHALL use the returned preference immediately
- **AND** the other tabs SHALL use the new preference after their next reload or authenticated mount
