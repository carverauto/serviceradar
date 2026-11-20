## ADDED Requirements

### Requirement: Syslog profile document
The system SHALL accept a syslog profile document with schema `serviceradar.syslog.profile.v1` containing an operating-system name, prefix matchers, and message matchers. Each message matcher MUST name an event, a tag, a line template, value patterns, and the attributes and optional YANG mapping written on a match.

#### Scenario: Profile names a Junos interface-down message
- **WHEN** a profile for `junos` includes a message with event `INTERFACE_DOWN` and tag `SNMP_TRAP_LINK_DOWN`
- **THEN** the matcher SHALL be able to load that message by tag
- **AND** the message SHALL carry the line template and value patterns needed to extract the interface name and status fields

### Requirement: Tag-indexed message match
The system SHALL match a syslog record against a profile by candidate tags, then by that tag's line templates only. Candidate tags MUST include `application_name` and the leading token of `short_message` when that token is an identifier. A single space in a line template MUST match one or more whitespace characters, and the search MUST be case-insensitive. The first matching message in profile order SHALL win.

#### Scenario: Parsed collector record matches on the body tag
- **GIVEN** a junos profile is loaded
- **AND** a record has `application_name` `mib2d` and `short_message` `SNMP_TRAP_LINK_DOWN: ifIndex 502, ifAdminStatus down(2), ifOperStatus down(2), ifName xe-0/0/0`
- **WHEN** the profile rule runs
- **THEN** the match SHALL be event `INTERFACE_DOWN`
- **AND** `network.interface.name` SHALL be `xe-0/0/0`

#### Scenario: Unrelated tag skips the line templates
- **GIVEN** a profile whose messages are tagged `SNMP_TRAP_LINK_DOWN`
- **WHEN** a record's candidate tags do not include `SNMP_TRAP_LINK_DOWN`
- **THEN** the rule SHALL NOT test those line templates
- **AND** the record SHALL be unchanged

### Requirement: Raw syslog prefix fallback
The system SHALL run a profile's prefix matchers when `short_message` still contains a raw syslog line, and SHALL take the tag and message section from the first prefix that matches.

#### Scenario: Raw Junos line is split before the message match
- **GIVEN** the junos profile prefixes are loaded
- **WHEN** `short_message` is `<28>Jul 20 21:45:59 vmx01 mib2d[2424]: SNMP_TRAP_LINK_DOWN: ifIndex 502, ifAdminStatus down(2), ifOperStatus down(2), ifName xe-0/0/0`
- **THEN** the matcher SHALL select tag `SNMP_TRAP_LINK_DOWN`
- **AND** the message match SHALL use the text after that tag

### Requirement: Closed transform set
The system SHALL apply only the transforms `upper`, `str`, `int`, `bgp_state_convert`, `bfd_state_convert`, and `color_to_severity` to captured values, using the napalm-logs mappings for BGP state, BFD state, and alarm color. A profile that names any other transform MUST be rejected at pack validation. A live `int` capture that is not a base-10 integer MUST fail that message match.

#### Scenario: BGP state is mapped
- **WHEN** a capture `Up` is transformed with `bgp_state_convert`
- **THEN** the stored value SHALL be `ESTABLISHED`

#### Scenario: Unknown transform is rejected
- **WHEN** a pack rule with template `syslog_profile` names transform `rot13`
- **THEN** pack validation SHALL reject the rule
- **AND** the rule SHALL NOT be installed

### Requirement: Match attributes keep the raw body
The system SHALL, on a match, set `syslog.os`, `syslog.event`, `syslog.tag`, `syslog.profile`, and `syslog.matched` true, plus the message's declared attributes, `syslog.fields`, and `syslog.yang` when a mapping exists. The system MUST NOT modify `short_message`, `full_message`, `host`, `application_name`, `level`, `severity_text`, or `severity_number`.

#### Scenario: Interface status is added beside the original body
- **WHEN** a message matches `INTERFACE_DOWN`
- **THEN** `syslog.event` SHALL be `INTERFACE_DOWN`
- **AND** `short_message` SHALL still contain the original message text

### Requirement: First match wins across profile rules
The system SHALL skip a syslog profile rule when `syslog.matched` is already true, so a later platform rule and a second evaluation of the same bundle leave the first match in place.

#### Scenario: Core evaluation does not overwrite the collector match
- **GIVEN** a record already has `syslog.matched` true and `syslog.event` `INTERFACE_DOWN`
- **WHEN** another syslog profile rule runs
- **THEN** `syslog.event` SHALL remain `INTERFACE_DOWN`

### Requirement: Profile errors do not drop the log
The system SHALL keep the original record when a syslog profile rule fails to compile or the custom node returns an error, and SHALL increment `zen_syslog_profile_errors` with the rule name. An unmatched message MUST NOT increment that error counter.

#### Scenario: Broken profile still stores the log
- **WHEN** a `syslog_profile` rule fails during evaluation
- **THEN** the log record SHALL still be ingested
- **AND** `syslog.matched` SHALL be absent
- **AND** `zen_syslog_profile_errors` SHALL increment for that rule name

### Requirement: Corpus equivalence with napalm-logs
The system SHALL ship a test corpus of the 133 `syslog.msg` fixtures under napalm-logs `tests/config` at commit `1f7b06f808156812bab07d1c622fa1d0ba91f2d5`, and each fixture MUST produce the same `syslog.os`, `syslog.event`, and `syslog.yang` object as that fixture's `yang.json` `yang_message` and `error` fields.

#### Scenario: Junos interface-down fixture
- **WHEN** the corpus runs `<28>Jul 20 21:45:59 vmx01 mib2d[2424]: SNMP_TRAP_LINK_DOWN: ifIndex 502, ifAdminStatus down(2), ifOperStatus down(2), ifName xe-0/0/0` through the junos profile
- **THEN** `syslog.os` SHALL be `junos`
- **AND** `syslog.event` SHALL be `INTERFACE_DOWN`
- **AND** `syslog.yang` SHALL record oper status and admin status `DOWN` for interface `xe-0/0/0`
