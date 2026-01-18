## ADDED Requirements

### Requirement: Device Stats GROUP BY Support

The SRQL service SHALL support GROUP BY aggregations for the devices entity using the syntax `stats:<agg>() as <alias> by <field>`.

Supported grouping fields:
- `type` / `device_type`: Device type classification
- `vendor_name` / `vendor`: Device vendor/manufacturer
- `risk_level`: Risk level classification
- `is_available` / `available`: Availability status (boolean)
- `gateway_id`: Gateway assignment

The response SHALL return a JSONB array of objects, each containing the group field value and the aggregated count, ordered by count descending with a default limit of 20 results.

#### Scenario: Group devices by type
- **GIVEN** devices exist with various type values
- **WHEN** a client sends `in:devices stats:count() as count by type`
- **THEN** SRQL returns `{"results": [{"type": "Server", "count": 45}, {"type": "Router", "count": 23}, ...]}`
- **AND** results are ordered by count descending

#### Scenario: Group devices by vendor
- **GIVEN** devices exist with various vendor_name values
- **WHEN** a client sends `in:devices stats:count() as count by vendor_name`
- **THEN** SRQL returns `{"results": [{"vendor_name": "Cisco", "count": 200}, {"vendor_name": "Dell", "count": 150}, ...]}`
- **AND** results are limited to top 20 vendors

#### Scenario: Group devices by availability
- **GIVEN** devices exist with is_available true and false
- **WHEN** a client sends `in:devices stats:count() as count by is_available`
- **THEN** SRQL returns `{"results": [{"is_available": true, "count": 950}, {"is_available": false, "count": 50}]}`

#### Scenario: Group devices by risk level
- **GIVEN** devices exist with various risk_level values
- **WHEN** a client sends `in:devices stats:count() as count by risk_level`
- **THEN** SRQL returns `{"results": [{"risk_level": "Low", "count": 800}, {"risk_level": "High", "count": 50}, ...]}`

#### Scenario: Combined filter with grouping
- **GIVEN** devices exist from multiple vendors with various types
- **WHEN** a client sends `in:devices vendor_name:Cisco stats:count() as count by type`
- **THEN** SRQL returns only Cisco devices grouped by type

#### Scenario: Null values handled as Unknown
- **GIVEN** devices exist with NULL vendor_name values
- **WHEN** a client sends `in:devices stats:count() as count by vendor_name`
- **THEN** devices with NULL vendor_name SHALL be grouped under "Unknown"

#### Scenario: Unsupported group field returns error
- **GIVEN** a client wants to group by an unsupported field
- **WHEN** they send `in:devices stats:count() as count by hostname`
- **THEN** SRQL returns an error indicating the field does not support grouping
