## ADDED Requirements
### Requirement: Policy reconciliation executes SRQL server-side
Plugin target policy reconciliation SHALL execute SRQL queries in the control plane and SHALL NOT require plugins to execute SRQL.

#### Scenario: Plugin receives resolved target batch
- **GIVEN** a plugin target policy with SRQL query `in:devices type:camera brand:axis`
- **WHEN** reconciliation runs
- **THEN** SRQL execution SHALL occur in the control plane
- **AND** plugin assignments SHALL include concrete resolved targets
- **AND** no SRQL/API credentials SHALL be provided to the plugin runtime
