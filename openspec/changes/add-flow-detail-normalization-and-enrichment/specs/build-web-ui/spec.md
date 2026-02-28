## ADDED Requirements

### Requirement: Flow detail UI SHALL render persisted enrichment fields
Flow detail views in web-ng SHALL render protocol, TCP flag, service, directionality, provider-hosting context, and MAC vendor context from persisted enriched flow fields returned by SRQL/API. The UI SHALL NOT recompute these enrichments from raw protocol/port/byte/MAC fields when persisted values are present.

#### Scenario: Persisted enrichment fields drive rendering
- **GIVEN** a flow detail response includes persisted `protocol_label`, `tcp_flag_labels`, `dst_service_label`, `directionality_class`, `provider_class`, and MAC vendor labels
- **WHEN** an operator opens flow details in `/flows`
- **THEN** the UI renders those persisted fields directly
- **AND** does not invoke fallback runtime mapping for those attributes

#### Scenario: Device drill-in uses same persisted enrichment values
- **GIVEN** the same flow is opened from device details drill-in
- **WHEN** flow details render
- **THEN** protocol/service/tcp-flag/direction/provider/MAC-vendor labels match `/flows` exactly

### Requirement: Flow detail UI SHALL expose enrichment provenance
The flow detail UI SHALL display enrichment provenance metadata where available so operators can distinguish authoritative mappings from heuristic or unknown results.

#### Scenario: Authoritative provider mapping shown
- **GIVEN** a flow detail includes `provider_class = hosting` and `provider_source = cloud_provider_db`
- **WHEN** the operator views flow details
- **THEN** the UI displays hosting/provider context
- **AND** indicates the source as dataset-driven

#### Scenario: Unknown mapping shown explicitly
- **GIVEN** a flow detail includes unknown service or provider mapping
- **WHEN** flow details render
- **THEN** the UI shows an explicit unknown state
- **AND** raw values (such as destination port and protocol number) remain visible

#### Scenario: OUI-driven MAC vendor mapping shown
- **GIVEN** a flow detail includes source or destination MAC vendor labels with `vendor_source = ieee_oui`
- **WHEN** the operator views endpoint details
- **THEN** the UI displays MAC vendor names for available endpoints
- **AND** indicates that vendor attribution came from the IEEE OUI dataset
