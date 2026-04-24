## ADDED Requirements

### Requirement: Geo-enriched flow aggregations
The SRQL engine SHALL support flow aggregations grouped by cached GeoIP fields (country-level at minimum) for both source and destination endpoints.

#### Scenario: Aggregate bytes by destination country
- **GIVEN** GeoIP cache entries exist in `platform.ip_geo_enrichment_cache`
- **WHEN** a client queries `in:flows time:last_1h stats:sum(bytes_total) as bytes by dst_country_iso2`
- **THEN** SRQL returns results grouped by destination country ISO2 code
- **AND** SRQL does not perform any external network calls to answer the query

### Requirement: Multi-dimension aggregation for Sankey
The SRQL engine SHALL support multi-dimension aggregation queries suitable for building Sankey graphs for flows.

#### Scenario: Subnet -> service -> subnet edges by bytes
- **WHEN** a client queries `in:flows time:last_15m stats:sum(bytes_total) as bytes by src_subnet:/24, service, dst_subnet:/24`
- **THEN** SRQL returns a list of rows that can be interpreted as weighted edges
