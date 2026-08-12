# srql

## MODIFIED Requirements

### Requirement: Device Stats GROUP BY Support

The SRQL service SHALL support GROUP BY aggregations for the devices entity using the syntax `stats:<agg>() as <alias> by <field>`.

Supported grouping fields:
- `type` / `device_type`: Device type classification
- `vendor_name` / `vendor`: Device vendor/manufacturer
- `risk_level`: Risk level classification
- `is_available` / `available`: Availability status (boolean)
- `is_active` / `active`: Lifecycle state (boolean)
- `gateway_id`: Gateway assignment
- `tags.<key>`: Any key of the device `tags` JSONB map
- `metadata.<key>`: Any key of the device `metadata` JSONB map

For a JSONB sub-key group, the service SHALL name the result column by its full
path (for example `tags.gate`), SHALL group devices that lack the key under the
value `Unknown` rather than excluding them, and SHALL accept that same full path
in `sort:`.

The JSONB key is interpolated into the generated SQL rather than supplied as a
bind parameter, because PostgreSQL has no placeholder for a JSONB key. The
service SHALL therefore validate the key against the same character whitelist
used for JSONB sub-key filters and SHALL reject any key that fails it.

The response SHALL return a JSONB array of objects, each containing the group field value and the aggregated count, ordered by count descending with a default limit of 20 results and a maximum of 100.

#### Scenario: Group devices by type

- **WHEN** a client issues `in:devices stats:count() as total by type`
- **THEN** the service SHALL return one object per distinct device type, each carrying the type and its count, ordered by count descending

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

#### Scenario: Group devices by a tag sub-key

- **WHEN** a client issues `in:devices stats:count() as total by tags.gate limit:100`
- **THEN** the service SHALL return one object per distinct value of the `gate` tag, keyed `tags.gate`, with devices carrying no `gate` tag counted under `Unknown`

#### Scenario: Filter by one tag while grouping by another

- **WHEN** a client issues `in:devices tags.site:ZZA stats:count() as total by tags.gate limit:100`
- **THEN** the service SHALL apply the `tags.site` filter and return gate counts computed only over the matching devices

#### Scenario: JSONB group keys are case-sensitive

- **WHEN** a client issues `in:devices stats:count() as total by tags.Gate`
- **THEN** the service SHALL read the key exactly as written and SHALL NOT fold it to `tags.gate`

#### Scenario: Sort case-sensitive JSONB groups independently

- **WHEN** a client groups by both `tags.Gate,tags.gate` and sorts by `tags.gate`
- **THEN** the service SHALL order by the lowercase `gate` group expression and SHALL NOT substitute the distinct `Gate` key

#### Scenario: Reject a grouping key that is not safe to interpolate

- **WHEN** a client issues a grouping field whose JSONB key contains a character outside the permitted set, such as `by tags.a'b`
- **THEN** the service SHALL reject the query with an error naming the unsupported grouping field and SHALL NOT execute any SQL

#### Scenario: Grouped stats execute against the database

- **WHEN** any grouped device stats query carries at least one filter, so that the generated SQL contains bind parameters
- **THEN** the service SHALL rewrite placeholders to the PostgreSQL `$n` form before execution and the query SHALL succeed rather than fail as a syntax error

## ADDED Requirements

### Requirement: Device JSONB Sub-key Filters

The SRQL service SHALL support filtering devices on a key of a JSONB column via `tags.<key>:<value>`, `metadata.<key>:<value>`, and the fixed paths `os.<field>` and `hw_info.<field>`.

These filters SHALL support equality (`=`), negated equality, `LIKE` and negated `LIKE` via the `%` wildcard, and list membership via `field:(a,b)` and its negation.

A negated match SHALL treat a device that lacks the key entirely as satisfying the negation, so that such devices are returned rather than silently dropped by SQL NULL semantics.

Field names SHALL be matched case-insensitively for the column namespace only. The JSONB key SHALL retain the casing the client wrote, because PostgreSQL JSONB keys are case-sensitive and tag ingestion preserves the casing supplied by the operator.

The bare form `tags:<key>` SHALL test whether the key exists on the device, not whether any value equals it, and its list form `tags:(a,b)` SHALL match a device carrying any of the named keys.

#### Scenario: Filter by a tag value

- **WHEN** a client issues `in:devices tags.gate:B40`
- **THEN** the service SHALL return only devices whose `gate` tag equals `B40`

#### Scenario: Filter a tag value with a wildcard

- **WHEN** a client issues `in:devices tags.role:%edge%`
- **THEN** the service SHALL apply a case-insensitive LIKE match to the `role` tag rather than compare the literal string `%edge%` for equality

#### Scenario: Filter by a list of tag values

- **WHEN** a client issues `in:devices tags.gate:(B40,B41)`
- **THEN** the service SHALL return devices whose `gate` tag is either value

#### Scenario: Negated list keeps devices missing the key

- **WHEN** a client issues `in:devices !tags.gate:(B40)`
- **THEN** the service SHALL return devices whose `gate` tag is not `B40` **and** devices that carry no `gate` tag at all

#### Scenario: Tag key existence

- **WHEN** a client issues `in:devices tags:gate`
- **THEN** the service SHALL return every device that carries a `gate` key, whatever its value

#### Scenario: JSONB filter keys are case-sensitive

- **WHEN** a client issues `in:devices tags.Gate:A1`
- **THEN** the service SHALL probe the key `Gate` exactly as written, matching the behaviour of `by tags.Gate`

#### Scenario: Reject a filter key that is not safe to interpolate

- **WHEN** a client issues a filter whose JSONB key contains a character outside the permitted set, such as `tags.a'b:x`
- **THEN** the service SHALL reject the query with an error naming the invalid key and SHALL NOT execute any SQL

#### Scenario: Translation and execution accept the same operators

- **WHEN** a client issues a JSONB sub-key filter in any supported operator form, including the list form on a fixed path such as `os.name:(Linux,Windows)`
- **THEN** both the execution path and the SQL translation path SHALL accept it, producing the same number of bind parameters as placeholders
