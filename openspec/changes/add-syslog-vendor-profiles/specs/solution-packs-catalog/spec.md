## ADDED Requirements

### Requirement: Syslog profile packs use the zen_rule kind
The system SHALL distribute vendor syslog profiles as Solution Pack rules with `kind` `zen_rule`, template `syslog_profile`, subject `logs.syslog`, stream `events`, and format `json`. The profile document MUST be the rule's `builder_config`. Installing the pack MUST compile that document into a JDM graph whose custom node `syslog_profile` contains the profile, and MUST publish the compiled rule on the existing Zen bundle for `events` / `logs.syslog`. The system MUST NOT add a separate pack resource kind for these profiles.

#### Scenario: Installing the Junos pack publishes one zen rule
- **WHEN** an operator installs the built-in pack `io.serviceradar.syslog-junos`
- **THEN** the tenant SHALL gain one managed Zen rule named `syslog_profile_junos` at order 112
- **AND** the published `logs.syslog` bundle SHALL include that rule's compiled JDM
- **AND** the JDM custom node configuration SHALL contain the junos profile document

#### Scenario: Uninstall withdraws the rule from the bundle
- **GIVEN** `syslog_profile_junos` was installed by the Junos syslog pack
- **WHEN** the operator uninstalls that pack
- **THEN** the managed rule SHALL be disabled or removed
- **AND** the published bundle SHALL no longer contain `syslog_profile_junos`

### Requirement: Syslog profile packs are catalog entries
The system SHALL ship one built-in Solution Pack per platform for eos, fortinet, huawei, ios, iosxr, junos, netiron, nxos, opengear, and sonic. The system MUST NOT insert those Zen rules into a tenant that has not installed the pack.

#### Scenario: New tenant has no vendor syslog rules
- **WHEN** a tenant is created and no syslog profile pack is installed
- **THEN** the tenant's `logs.syslog` rules SHALL be the seeded passthrough, Coraza, strip-full-message, syslog severity, and CEF severity rules
- **AND** no `syslog_profile_*` rule SHALL be present

### Requirement: Syslog profile pack validation
The system SHALL reject a `zen_rule` whose template is `syslog_profile` when `builder_config` is not a `serviceradar.syslog.profile.v1` document, when a transform is outside the closed set, when a value pattern does not compile, or when a pattern is on the nested-repetition rejection list.

#### Scenario: Invalid profile fails validation
- **WHEN** a pack contains a `syslog_profile` rule whose `builder_config` omits `messages`
- **THEN** pack validation SHALL fail
- **AND** the pack SHALL NOT be installed
