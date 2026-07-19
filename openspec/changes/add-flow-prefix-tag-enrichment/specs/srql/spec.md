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
