## ADDED Requirements
### Requirement: Interface MAC filters support normalization and wildcards
The SRQL service SHALL support `mac` filters for `in:interfaces` queries with case-insensitive, separator-insensitive matching and `%` wildcard patterns.

#### Scenario: Exact MAC match with mixed separators
- **GIVEN** an interface stored with MAC address `0e:ea:14:32:d2:78`
- **WHEN** a client sends `in:interfaces mac:0E-EA-14-32-D2-78`
- **THEN** SRQL returns the interface in the results

#### Scenario: Wildcard MAC match in interface search
- **GIVEN** an interface stored with MAC address `0e:ea:14:32:d2:78`
- **WHEN** a client sends `in:interfaces mac:%0e:ea:14:32:d2:78%`
- **THEN** SRQL executes successfully and returns the interface in the results
