## ADDED Requirements

### Requirement: Warehouse Retention Is A DB-Backed Operator Setting
Retention for every StarRocks warehouse dataset (flows, metrics, logs, events, mtr, otel, traces, bmp, attribution) SHALL be stored as a deployment-scoped control-plane setting in CNPG, editable on an RBAC-gated Data retention settings page. Environment, Helm and Compose retention values SHALL seed a dataset's setting only when no stored setting exists. Existing datasets SHALL default to 365 days and the attribution dataset to 30 days.

#### Scenario: Seed default from Helm
- **GIVEN** Helm sets `analytics.starrocks.retentionDays.logs` to 180 and no stored setting exists for logs
- **WHEN** core starts
- **THEN** the logs retention setting is created with 180 days
- **AND** a later change on the settings page takes precedence over the Helm value

#### Scenario: Unset dataset uses the product default
- **GIVEN** no stored setting and no seed value for the metrics dataset
- **WHEN** core starts
- **THEN** the metrics retention setting is 365 days

### Requirement: Retention Changes Apply To The Warehouse Without Restart
Saving a dataset's retention SHALL re-apply `partition_live_number` to every table of that dataset without restarting core, retrying with capped backoff while the warehouse is unavailable, and SHALL record the last applied value, status and error so the settings page shows whether the warehouse took the value.

#### Scenario: Setting change applies without restart
- **GIVEN** the events dataset is retained for 365 days
- **WHEN** an operator with retention-manage permission sets it to 90 days
- **THEN** core issues `ALTER TABLE ... SET ("partition_live_number" = "90")` for the events tables
- **AND** records the dataset as applied at 90 days
- **AND** no restart occurs

#### Scenario: Warehouse temporarily unavailable
- **GIVEN** the StarRocks Frontend does not answer
- **WHEN** an operator saves a retention change
- **THEN** the dataset is recorded as pending and the applier retries with backoff until it succeeds

### Requirement: Retention Floors Are Enforced
Each dataset SHALL have a minimum retention enforced when saved and when applied; the attribution dataset's minimum is 1 day. Values above a storage threshold SHALL be accepted with a warning.

#### Scenario: Below-floor value is rejected
- **WHEN** an operator sets the attribution dataset's retention to 0 days
- **THEN** the change is rejected with an error naming the 1-day minimum
- **AND** the stored setting and the warehouse are unchanged

#### Scenario: Large value warns
- **WHEN** an operator sets a dataset's retention far above its default
- **THEN** the page shows a storage warning
- **AND** the value is saved and applied
