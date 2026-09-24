## ADDED Requirements

### Requirement: Explicit query limits are not silently reduced
When a caller supplies `limit:`, the SRQL service MUST compile that limit. The service MUST NOT replace it with a smaller hard cap and still return success. When a grouped aggregation returns a page that is not the full grouping, the response MUST indicate that the grouping is partial. When the caller omits `limit:`, the service MAY apply a documented default page.

This requirement applies to device grouped stats and to composite-result grouped stats. Interactive LiveView pages MAY keep their own page size by passing a smaller request limit. That page size is the caller's limit, not a hidden engine clamp.

#### Scenario: Device group-by honors an explicit limit
- **WHEN** a client sends `in:devices stats:count() as total by type limit:250`
- **THEN** the compiled query SHALL use `LIMIT 250`
- **AND** the service SHALL NOT reduce it to 100

#### Scenario: Omitted device group-by limit stays a default page
- **WHEN** a client sends `in:devices stats:count() as total by type` and more than 20 groups exist
- **THEN** the service SHALL return at most the documented default of 20 groups
- **AND** the response SHALL indicate that further groups exist

#### Scenario: Composite group-by does not silently cap an explicit limit
- **WHEN** a client sends a supported `in:composite_results` grouped `count()` with `limit:800`
- **THEN** the compiled query SHALL use `LIMIT 800`
- **AND** the service SHALL NOT reduce it to 500

### Requirement: Window scans can page past the interactive cursor ceiling
Ordinary interactive SRQL queries MUST keep the configured cursor-offset ceiling and MUST return an error when the next page would pass it. A maintenance or analytic read whose contract is to cover a time window MUST be able to continue until that window is exhausted, using the same class of exemption already used by exhaustive `profile_hour_of_week` queries. That read MUST NOT treat the interactive ceiling error as the end of the data.

#### Scenario: Interactive log paging stops with an error
- **WHEN** an interactive log query asks for the page after the configured cursor-offset ceiling
- **THEN** the service SHALL reject the request with a cursor-limit error

#### Scenario: A window-coverage read finishes the window
- **WHEN** a capacity, seasonal, or netflow cache read must see every row in its window and that window contains more rows than the interactive cursor ceiling
- **THEN** the read SHALL continue until the window is exhausted
- **AND** it SHALL NOT stop at the interactive ceiling and report success
