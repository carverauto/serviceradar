## ADDED Requirements
### Requirement: Timeseries ingestion only deduplicates exact series duplicates
The system SHALL deduplicate timeseries metric batches only when samples share the exact same series identity and timestamp. Distinct device, interface, check, or plugin series that share a metric name SHALL remain separate through ingestion.

#### Scenario: SNMP interface metrics are not collapsed by metric name alone
- **GIVEN** a payload contains multiple SNMP interface counters with the same `metric_name` and timestamp
- **WHEN** the observability ingest pipeline normalizes the payload
- **THEN** it SHALL preserve one row per distinct interface series
- **AND** it SHALL NOT collapse them solely because `metric_name` matches

#### Scenario: Plugin metrics use series-specific identities
- **GIVEN** two plugin results emit the same metric name at the same time for different plugin/check labels
- **WHEN** the plugin metrics ingestor writes timeseries samples
- **THEN** each distinct series SHALL receive its own `series_key`
- **AND** only exact duplicate samples for the same series SHALL deduplicate
