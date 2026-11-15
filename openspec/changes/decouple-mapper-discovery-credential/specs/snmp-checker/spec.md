## ADDED Requirements

### Requirement: Default profile flag scope
An SNMP profile's `is_default` flag SHALL affect only SNMP polling fallback, and saving a profile's edit form MUST NOT change the flag.
Only the explicit "Clear default" action (`:unset_default`) and making another profile the default (`:set_as_default`) change it. Mapper discovery does not read the flag.

#### Scenario: Editing the default profile keeps it default
- **GIVEN** an SNMP profile with `is_default = true`
- **WHEN** an operator changes its target query to `in:devices hostname:host01.example.com` in the profile edit form and saves
- **THEN** the profile SHALL still have `is_default = true`

#### Scenario: Clearing the default does not touch discovery
- **GIVEN** an SNMP profile with `is_default = true`
- **AND** an SNMP-mode mapper job referencing its own SNMP credential
- **WHEN** an operator clears the profile's default flag
- **THEN** devices matching no other profile SHALL stop being polled
- **AND** the mapper job's compiled base credentials SHALL be unchanged
