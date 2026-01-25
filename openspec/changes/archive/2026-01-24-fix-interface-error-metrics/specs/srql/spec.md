## ADDED Requirements
### Requirement: Interface error counters are projected in SRQL results
SRQL `in:interfaces` queries SHALL project interface error counter fields (`in_errors`, `out_errors`) when present, and SHALL return nulls when the fields are not available.

#### Scenario: Latest interface query includes error counters
- **GIVEN** interface metrics contain `in_errors` and `out_errors` values
- **WHEN** a client queries `in:interfaces device_id:"sr:<uuid>" interface_uid:"ifindex:3" latest:true limit:1`
- **THEN** the result payload includes `in_errors` and `out_errors` with the latest values

#### Scenario: Missing fields return nulls
- **GIVEN** interface metrics do not include error counter values for an interface
- **WHEN** a client queries `in:interfaces device_id:"sr:<uuid>" interface_uid:"ifindex:3" latest:true limit:1`
- **THEN** the result payload includes `in_errors: null` and `out_errors: null`
