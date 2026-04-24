## ADDED Requirements

### Requirement: Device-scoped flow queries
The SRQL service SHALL support `device_id` filtering for `in:flows` queries so clients can request flows in a device scope using canonical device UID values (for example `sr:<uuid>`).

#### Scenario: Device-scoped flow list query
- **GIVEN** a device identity value `sr:<uuid>`
- **WHEN** a client queries `in:flows device_id:"sr:<uuid>" time:last_24h sort:time:desc limit:50`
- **THEN** SRQL returns only flow rows associated with that device identity within the requested time window

#### Scenario: Device scope matches exporter-owned flows
- **GIVEN** `platform.netflow_exporter_cache` contains a row where `device_uid` equals `sr:<uuid>`
- **WHEN** a client queries `in:flows device_id:"sr:<uuid>"`
- **THEN** SRQL includes flow rows whose `sampler_address` matches that exporter cache row

#### Scenario: Device scope matches endpoint IP flows
- **GIVEN** device `sr:<uuid>` has a primary IP and active IP aliases
- **WHEN** a client queries `in:flows device_id:"sr:<uuid>"`
- **THEN** SRQL includes flow rows where `src_endpoint_ip` or `dst_endpoint_ip` matches one of those device IP values

### Requirement: Device-scoped flows support deterministic pagination
Device-scoped `in:flows` queries SHALL apply deterministic ordering for paginated results, including a stable tie-breaker when multiple rows share the same primary sort value.

#### Scenario: Stable pages across repeated requests
- **GIVEN** a client requests page 1 and page 2 for `in:flows device_id:"sr:<uuid>"` with identical filter and sort tokens
- **WHEN** no new matching flow rows arrive between requests
- **THEN** SRQL returns non-overlapping rows across pages in a deterministic order
