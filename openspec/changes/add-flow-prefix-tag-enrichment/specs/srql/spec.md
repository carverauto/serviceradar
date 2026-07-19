# srql Specification (Delta)

## ADDED Requirements

### Requirement: Flow prefix tag filtering

SRQL flow queries (`in:flows`) SHALL support filtering on prefix tags via a `tag`
field that matches when the given tag is present on either the source or destination
tag column, plus directional fields (`src_tag`, `dst_tag`) that match one side only.
Tag filters SHALL be translated to indexed predicates over the
`src_prefix_tags`/`dst_prefix_tags` columns on `platform.ocsf_network_activity` and
SHALL compose with existing flow filters (time range, CIDR literals, ports,
protocol, device scope).

#### Scenario: Tag filter matches either direction

- **WHEN** a user queries `in:flows tag:site:austin`
- **THEN** results include flows where `site:austin` appears in the source tags, the
  destination tags, or both

#### Scenario: Directional tag filter

- **WHEN** a user queries `in:flows dst_tag:role:guest-wifi`
- **THEN** results include only flows whose destination tags contain
  `role:guest-wifi`, regardless of source tags

#### Scenario: Tag filter composes with existing filters

- **WHEN** a user queries `in:flows tag:tenant:acme src_ip:10.0.0.0/8` with a time
  range
- **THEN** the translated query applies the tag predicate, the CIDR predicate, and
  the time range together and returns only rows satisfying all of them

### Requirement: Flow geographic proximity filtering

SRQL flow queries SHALL support a proximity filter that accepts a coordinate
and radius and matches flows whose source or destination IP geolocates within
that radius. The translation SHALL evaluate the spatial predicate
(`ST_DWithin`) against the PostGIS-indexed geometry column on
`platform.ip_geo_enrichment_cache` to produce an IP set, and SHALL apply that
set as a membership filter on the flow columns - it SHALL NOT require or
evaluate per-row geometry on the flow hypertable. Proximity SHALL compose
with tag, CIDR, and time-range filters. Addresses absent from the geo cache
are excluded from proximity matches without error.

#### Scenario: Proximity filter returns nearby flows

- **WHEN** a user queries flows with a proximity term for a coordinate and a
  50 km radius, and the geo cache places a flow's destination IP 10 km from
  that coordinate
- **THEN** the flow is returned, and flows whose cached coordinates fall
  outside the radius are not

#### Scenario: Proximity composes with threat tags

- **WHEN** a user combines a `ti:` tag filter with a proximity term and a time
  range
- **THEN** the query returns only flows satisfying all three predicates, with
  the spatial predicate evaluated against the geo cache index rather than the
  flow rows

#### Scenario: Un-geolocated addresses do not error

- **WHEN** a proximity-filtered query scans flows whose IPs have no geo cache
  entry
- **THEN** those flows are simply excluded from proximity matches and the
  query completes normally
