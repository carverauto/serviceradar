## ADDED Requirements
### Requirement: Authentication Rate Limiting Remains Bounded Under Flood
The authentication rate limiter SHALL keep per-key in-memory state bounded to the active window instead of accumulating unbounded historical attempts between cleanup cycles.

#### Scenario: Repeated attempts do not grow state beyond the active window
- **GIVEN** repeated authentication attempts from the same key
- **WHEN** the rate limiter records attempts over time
- **THEN** it SHALL retain only attempts within the configured active window for that key
- **AND** stale attempts SHALL be discarded on write
