## ADDED Requirements

### Requirement: NetFlow dimension caches cover the scan window
The exporter cache refresh and the interface cache refresh MUST discover every sampler address and every `(sampler, if_index)` pair observed in the configured scan window. A single SQL `LIMIT` MAY bound one batch. It MUST NOT be the end of the discovery. The threat-candidate refresh MUST likewise walk every candidate in its window.

#### Scenario: More exporters than one discovery batch
- **WHEN** the scan window contains more distinct sampler addresses than one discovery batch
- **THEN** the exporter cache refresh SHALL upsert a row for every sampler address in that window

#### Scenario: More interface pairs than one discovery batch
- **WHEN** the scan window contains more observed interface pairs than one discovery batch
- **THEN** the interface cache refresh SHALL update every pair in that window

## MODIFIED Requirements

### Requirement: GeoIP cache population from observed NetFlow IPs
The system SHALL populate `platform.ip_geo_enrichment_cache` via background jobs using IPs observed in NetFlow flows, so SRQL queries can join against cached enrichment data. The job MUST walk every observed IP that is missing from the cache. It MUST NOT stop after a fixed top-N by byte volume and report the refresh complete.

#### Scenario: Newly-seen flow IP is enriched
- **GIVEN** NetFlow flows contain an IP that is not present in `platform.ip_geo_enrichment_cache`
- **WHEN** the cache population job runs
- **THEN** the system enriches the IP via the configured provider
- **AND** upserts a cache row for that IP

#### Scenario: Uncached IPs beyond the first page are still enriched
- **GIVEN** more observed flow IPs are missing from the cache than one query page
- **WHEN** the cache population job runs
- **THEN** each missing IP SHALL be enriched
- **AND** the job SHALL NOT treat the first page as the full uncached set
