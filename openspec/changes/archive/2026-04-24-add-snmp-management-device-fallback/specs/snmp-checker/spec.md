## ADDED Requirements

### Requirement: SNMP Polling via Management Device Fallback

The SNMP compiler SHALL use a device's management device IP as the polling host when `management_device_id` is set, so that devices discovered behind firewalls or NAT can still be polled via their parent device.

#### Scenario: Device with management device uses parent IP for polling
- **GIVEN** device `sr:child` has `ip = 203.0.113.5` and `management_device_id = sr:parent`
- **AND** device `sr:parent` has `ip = 192.168.1.1`
- **WHEN** the SNMP compiler builds the polling target for `sr:child`
- **THEN** the target `host` field SHALL be `192.168.1.1` (the management device's IP)
- **AND** the target OIDs SHALL still reference `sr:child`'s configured interfaces

#### Scenario: Device without management device uses its own IP
- **GIVEN** device `sr:standalone` has `ip = 10.0.0.1` and `management_device_id = nil`
- **WHEN** the SNMP compiler builds the polling target for `sr:standalone`
- **THEN** the target `host` field SHALL be `10.0.0.1`
