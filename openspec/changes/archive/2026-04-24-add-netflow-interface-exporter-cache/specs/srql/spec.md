## ADDED Requirements

### Requirement: Flow exporter/interface dimensions

The SRQL service SHALL expose exporter and interface metadata dimensions for `in:flows` queries, derived from cached inventory data.

#### Scenario: Group flows by exporter name
- **GIVEN** exporter cache rows exist for one or more `sampler_address` values
- **WHEN** the user queries `in:flows stats:sum(bytes_total) as bytes by exporter_name`
- **THEN** SRQL returns grouped rows keyed by `exporter_name`

#### Scenario: Downsample flows by inbound interface name
- **GIVEN** interface cache rows exist for one or more `(sampler_address, if_index)` pairs
- **WHEN** the user queries `in:flows downsample series:in_if_name value_field:bytes_total`
- **THEN** SRQL returns time-series grouped by `in_if_name`

#### Scenario: Missing cache entries do not break queries
- **GIVEN** flow rows exist with `sampler_address`/`if_index` values not present in the cache tables
- **WHEN** the user queries `in:flows exporter_name:*` or `in:flows stats:count() by in_if_name`
- **THEN** SRQL executes successfully and treats missing metadata as null/unknown

