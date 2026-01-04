## ADDED Requirements

### Requirement: SNMP PDU string types convert without panics
The SNMP checker MUST convert gosnmp PDU values of type `OctetString` and `ObjectDescription` into Go strings without panicking.

#### Scenario: Convert OctetString value returned as bytes
- **GIVEN** an SNMP response variable with Type `OctetString` and Value `[]byte("Test SNMP String")`
- **WHEN** the SNMP client converts the variable
- **THEN** the conversion result is the string `"Test SNMP String"` and conversion returns no error

#### Scenario: Convert ObjectDescription value returned as bytes
- **GIVEN** an SNMP response variable with Type `ObjectDescription` and Value `[]byte("Device OS v1.2.3")`
- **WHEN** the SNMP client converts the variable
- **THEN** the conversion result is the string `"Device OS v1.2.3"` and conversion returns no error

#### Scenario: Unexpected value type does not crash the checker
- **GIVEN** an SNMP response variable with Type `OctetString` or `ObjectDescription` and a Value that is not a `[]byte`
- **WHEN** the SNMP client converts the variable
- **THEN** conversion returns an error and the checker does not panic

