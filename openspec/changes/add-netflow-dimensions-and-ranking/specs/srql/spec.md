## ADDED Requirements

### Requirement: SRQL-Driven Top-N With "Other" Bucket
The system SHALL construct top-N datasets from SRQL results and bucket remaining series into an `Other` category.

#### Scenario: Top-N buckets remaining series
- **GIVEN** a time-series SRQL downsample result contains more than N series
- **WHEN** the Visualize page renders a top-N chart
- **THEN** it shows the top N series and aggregates the remaining series into `Other`
