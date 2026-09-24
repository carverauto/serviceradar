## ADDED Requirements

### Requirement: Interface Config Check Configuration
The `opentext-nom` plugin SHALL accept an interface config check configuration, supplied as plugin configuration on a credential rule, that defines the SRQL device target query, the device field holding the switch attachment, the interface block delimiters, optional interface shorthand expansions, and one or more named checks.
The configuration SHALL be validated when the run starts, and an invalid configuration SHALL fail the run with a safe error code rather than produce verdicts.

#### Scenario: Operator defines a NAC check
- **GIVEN** a credential rule whose plugin configuration sets `target_query` to `in:devices switch_port_attachment.switch_hostname:%`, `attachment_field` to `switch_port_attachment`, and a check named `nac` requiring the line `authentication port-control auto`
- **WHEN** the rule is saved
- **THEN** the plugin receives the target devices and the check definition on its next scheduled run

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

#### Scenario: Switch unknown to NA
- **GIVEN** NA returns an error or an empty block for the switch or interface
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
