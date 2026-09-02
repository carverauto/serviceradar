## ADDED Requirements

### Requirement: SNMP Requirements Materialize On Approval

`snmp_requirements` SHALL be materialized when a plugin package transitions to
`approved`, and SHALL NOT be materialized on import or on assignment.

A staged package's manifest has not been read by anyone, so nothing it declares
may reach the database before a human approves it. SNMP is a strictly stronger
case than alert rules: an approved requirement ultimately produces outbound
UDP/161 traffic from an agent to real inventory devices bearing real
credentials.

Materialization on **assignment** is likewise refused: assignment scopes a WASM
guest to an agent, whereas SNMP polling is performed by the agent's embedded
checker and scoped by the profile's own `agent_ids` and `target_query` - an
operator decision that the operator must be able to see and tune *before*
polling starts.

Each entry SHALL materialize as exactly two rows:

- one `snmp_oid_templates` row with `is_builtin: false` and the package's OIDs
- one `snmp_profiles` row referencing that template, created `enabled: false`,
  with no credentials bound and no agents bound

#### Scenario: Approving a package creates inert, editable configuration

- **WHEN** a package declaring one `snmp_requirements` entry is approved
- **THEN** one OID template row and one disabled profile row SHALL exist
- **AND** both SHALL be visible and editable in `/settings/snmp`

#### Scenario: Denying, revoking, or restaging disables without destroying

- **WHEN** an approved package is denied, revoked, or restaged
- **THEN** its materialized profiles SHALL be set `enabled: false`
- **AND** the template row and every operator edit SHALL be left intact

### Requirement: Plugin Provenance Is Visible In The UI

A materialized template and profile SHALL be rendered with a badge naming the
package that contributed it. When the contributing package has been removed and
the provenance reference is null, the badge SHALL indicate that the object was
plugin-contributed and that the package is gone.

Recording provenance in a column that no view reads does not satisfy this
requirement. Configuration that appears in the operator's list with no
explanation of where it came from is precisely the buried backend state this
change exists to avoid.

#### Scenario: An operator can tell plugin config from their own

- **WHEN** an operator opens `/settings/snmp` after approving a package
- **THEN** the materialized profile SHALL be labeled with the contributing
  package's name
- **AND** an operator-authored profile SHALL carry no such label

### Requirement: Upgrade Updates OIDs Only

Re-approving an upgraded package SHALL update the OID list of its materialized
templates and SHALL NOT write any other field of any materialized row.

`enabled`, `is_default`, `priority`, `agent_ids`, `target_query`,
`poll_interval`, `timeout`, `retries`, every credential attribute, and the
profile's `oid_template_ids` SHALL be written at creation and never again.

The split is deliberate and follows what each side actually knows. Which OIDs
carry which metric is intrinsic - a fact of the MIB, identical on every
deployment, and owned by the plugin that reads the results. Cadence, targeting,
credentials, and whether to poll at all are deployment facts, owned outright by
the operator.

#### Scenario: An operator's tuning survives a package upgrade

- **WHEN** an operator has disabled a materialized profile, narrowed its
  `target_query`, changed its cadence, and bound a credential, and the package
  is then upgraded and re-approved
- **THEN** all four operator changes SHALL be preserved
- **AND** any OID added by the new manifest version SHALL appear in the template

#### Scenario: Re-approval after revoke does not re-arm polling

- **WHEN** a revoked package - whose profiles were disabled - is approved again
- **THEN** the existing profile rows SHALL be updated rather than recreated
- **AND** they SHALL remain `enabled: false`

#### Scenario: An operator who wants different OIDs forks the template

- **WHEN** an operator needs an OID list that differs from the plugin's
- **THEN** they SHALL copy the template to an ordinary custom template that the
  catalog never writes to
- **AND** the forked template SHALL be unaffected by later package upgrades

### Requirement: A Profile That Would Collect Nothing Is Surfaced

An enabled profile that compiles to zero targets SHALL be surfaced to the
operator rather than logged at debug level.

`compile_device_target` skips a device with no resolvable host, no OIDs, or no
credentials, and each skip is a `Logger.debug`. An operator who enables a
materialized profile without binding a credential therefore gets a
successfully-compiled, enabled, empty configuration and no signal anywhere that
it collects nothing.

#### Scenario: Enabling without a credential warns

- **WHEN** an operator enables a profile that has neither a bound credential
  secret nor inline credentials
- **THEN** the interface SHALL warn that the profile will collect nothing

#### Scenario: Compiled target count is visible

- **WHEN** an operator views a profile in `/settings/snmp`
- **THEN** the number of devices it currently compiles to SHALL be shown

### Requirement: SNMP Results Are Stored Against The Device They Came From

Every value collected for a plugin-declared OID SHALL be attributable to the
`ocsf_devices` row it was polled from.

A `device_snmp_facts` table SHALL hold the latest value of each declared OID per
device, keyed on `device_uid` referencing `ocsf_devices.uid`, following the
convention already used by `DeviceRiskContribution`,
`BumblebeeDevicePosture`, and `EndpointInventoryPackage`. It SHALL be exposed as
a `has_many` on the `Device` resource.

Each row SHALL record the OID, its declared name, the collected value, the
declared `data_type`, the OID index when the value came from a walk, the
contributing plugin package, the profile that collected it, and the collection
timestamp.

Numeric OIDs SHALL continue to be written to `timeseries_metrics` as they are
today. This table is the current-state surface, not a replacement for the
time series.

#### Scenario: A string-valued OID is retained

- **WHEN** a declared OID with `data_type: string` is collected - a software
  version, a node role, a service name
- **THEN** its value SHALL be stored against the polled device
- **AND** it SHALL be readable without parsing it into a float

The metrics store cannot hold it: `timeseries_metrics.value` is a non-nullable
float, while `string` is a legal SNMP `data_type` that a plugin may declare.
Without this table such an OID could be polled successfully and then discarded.

#### Scenario: Walked rows keep their index

- **WHEN** a declared OID with `mode: walk` returns multiple rows
- **THEN** each row SHALL be stored with the OID index it was returned under
- **AND** rows from one walk SHALL be distinguishable from one another

#### Scenario: Facts are attributable to their source

- **WHEN** an operator inspects a device's SNMP facts
- **THEN** each SHALL name the plugin package that declared the OID and the
  profile that collected it

#### Scenario: Facts do not outlive their device

- **WHEN** a device is removed from inventory
- **THEN** its SNMP facts SHALL be removed with it

### Requirement: Declared OIDs May Be Gets Or Walks

An `snmp_requirements` OID entry SHALL support `mode: get` and `mode: walk`,
with `max_rows` and `walk_timeout_seconds` bounding a walk.

Walk mode requires no new plumbing: `compile_oid/1` already emits `mode`,
`max_rows`, and `walk_timeout_seconds`, and `build_snmp_oid_config/1` already
maps them into `Monitoring.SNMPOIDConfig`. A plugin declaring a walked MIB table
is therefore in scope for the first slice.

#### Scenario: A plugin declares a walked MIB table

- **WHEN** a package declares an OID with `mode: walk` and a `max_rows` bound
- **THEN** the materialized template SHALL carry the walk mode and its bounds
- **AND** the compiled agent config SHALL instruct the checker to walk it
