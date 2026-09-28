## ADDED Requirements

### Requirement: Interface Config Check Configuration
The `opentext-nom` plugin SHALL run interface config checks as its `opentext-nom.interface.check` producer schedule, configured on a credential rule whose plugin configuration defines the SRQL device target query, the device fields to deliver, and a check definition giving the attachment field, the interface block delimiters, optional shorthand expansions, and one or more named checks; the rule's cadence SHALL be the poll interval.
The configuration SHALL be validated when the run starts, and an invalid configuration SHALL fail the run with a safe error code rather than produce verdicts. Check names SHALL be lowercase identifiers of at most 44 characters.

#### Scenario: Operator defines a NAC check
- **GIVEN** a credential rule whose plugin configuration sets `target_query` to `in:devices switch_port_attachment.switch_hostname:%`, `target_fields` to `switch_port_attachment`, and a check definition with a check named `nac` requiring the line `authentication port-control auto`
- **WHEN** the schedule runs
- **THEN** the plugin receives the matched devices with their attachment and evaluates `nac` for each

#### Scenario: Invalid check is rejected
- **GIVEN** a check with an empty pattern list or an invalid regular expression
- **WHEN** a run starts
- **THEN** the run fails with `opentext_nom_check_config_invalid` and no device metadata is written

### Requirement: Attachment Resolution and Interface Name Expansion
The plugin SHALL resolve each target device's switch hostname and port from the configured attachment field, and SHALL expand a shorthand interface prefix to its full name using a built-in case-insensitive table that operator configuration can extend or override.
A map value SHALL be read from `switch_hostname` and `port`; a string value SHALL be split on its last `:`. A port without an alphabetic prefix SHALL be used unchanged. A device whose attachment is missing or unparsable SHALL receive status `unknown` with reason `attachment_missing`.

#### Scenario: Cisco shorthand is expanded
- **GIVEN** a device attachment of `switch01.example.com:gi1/0/7`
- **WHEN** the plugin resolves the interface
- **THEN** the switch is `switch01.example.com` and the interface is `GigabitEthernet1/0/7`

#### Scenario: Numeric port is kept
- **GIVEN** a device attachment whose port is `1/1/20`
- **WHEN** the plugin resolves the interface
- **THEN** the interface is `1/1/20`

#### Scenario: Missing attachment
- **GIVEN** a target device with no value in the configured attachment field
- **WHEN** the plugin evaluates it
- **THEN** the verdict is `unknown` with reason `attachment_missing` and no NA request is made for that device

### Requirement: Stored Interface Configlet Retrieval
The plugin SHALL retrieve the interface block from Network Automation's stored configuration with `show configlet` addressed by switch hostname, with `start` rendered from the configured template and `end` taken from configuration, and SHALL NOT send device show commands or open a device session.

#### Scenario: Configlet is requested by hostname
- **GIVEN** switch `switch01.example.com`, interface `GigabitEthernet1/0/7`, start template `interface {interface}` and end `!`
- **WHEN** the plugin retrieves the block
- **THEN** it sends `{"command":"show configlet","parameters":{"host":"switch01.example.com","start":"interface GigabitEthernet1/0/7","end":"!"}}`

#### Scenario: Interface has no configuration
- **GIVEN** NA knows the switch but the interface has no stanza, so it returns an empty block
- **WHEN** the plugin evaluates the device
- **THEN** the verdict is `non_compliant` with reason `interface_not_configured` and every required pattern listed as missing

#### Scenario: Switch unknown to NA
- **GIVEN** NA rejects the configlet request because it does not know the switch
- **WHEN** the plugin evaluates the device
- **THEN** the verdict is `unknown` with reason `configlet_not_found`

### Requirement: Declarative Interface Checks
Each check SHALL define required patterns, a match mode of `all` or `any`, whether patterns are literal substrings or regular expressions, and case sensitivity, and the plugin SHALL mark a device `compliant` when the retrieved block satisfies the check and `non_compliant` otherwise, reporting the patterns that were not found.
The retrieved configuration text SHALL NOT be included in the plugin result.

#### Scenario: All required lines present
- **GIVEN** a check with match `all` and patterns `authentication port-control auto` and `dot1x pae authenticator`
- **AND** the interface block contains both lines
- **WHEN** the check is evaluated
- **THEN** the verdict is `compliant` with no missing patterns

#### Scenario: A required line is missing
- **GIVEN** the same check and an interface block containing only `dot1x pae authenticator`
- **WHEN** the check is evaluated
- **THEN** the verdict is `non_compliant` and `missing` lists `authentication port-control auto`

### Requirement: Bounded Runs Report Coverage
The plugin SHALL check at most `max_targets` delivered endpoints (default 200) and SHALL stop issuing Network Automation requests once `run_budget_seconds` (default 1440, range 60 to 3600) has elapsed. Every delivered endpoint that is not checked for either reason SHALL be recorded as `unknown` with reason `target_limit_exceeded` rather than dropped. The run summary and result details SHALL report the number of skipped endpoints and the number the query matched beyond what the schedule delivered.

#### Scenario: More endpoints than max_targets
- **GIVEN** `max_targets` is 2 and three endpoints are delivered
- **WHEN** the run completes
- **THEN** the third endpoint's verdicts are `unknown` with reason `target_limit_exceeded`
- **AND** the run summary reports one endpoint not checked

#### Scenario: Run budget exhausted
- **GIVEN** the run budget has elapsed before an endpoint's configlet is requested
- **WHEN** the plugin reaches that endpoint
- **THEN** no request is sent to Network Automation and that endpoint and every remaining endpoint are `unknown` with reason `target_limit_exceeded`

#### Scenario: Core truncated the target set
- **GIVEN** the target query matched more devices than the schedule's `max_items`
- **WHEN** the run completes
- **THEN** the result details report the matched total and the number not delivered
