# Change: Fix SNMP PDU string conversion panics

## Why
GitHub issue `#2154` reports the SNMP client conversion layer panicking when decoding `gosnmp.SnmpPDU` values for `OctetString` and `ObjectDescription`. The gosnmp library returns these values as `[]byte`, but `pkg/checker/snmp/client.go` currently asserts `byte`, causing `interface conversion: interface {} is []uint8, not uint8` panics. This breaks common OIDs like `sysDescr` and can crash SNMP polling in normal configurations.

## What Changes
- Fix `OctetString` and `ObjectDescription` conversions to correctly decode `[]byte` into Go `string`.
- Ensure unexpected `Value` types for these ASN.1 types do not panic; conversion MUST fail with an error that callers can handle.
- Add regression tests covering `convertVariable()` for `OctetString` and `ObjectDescription` (and the non-panicking error case).

## Impact
- Affected specs: `snmp-checker`
- Affected code:
  - `pkg/checker/snmp/client.go`
  - `pkg/checker/snmp/*_test.go`
- Risk: low; change is localized to SNMP value decoding and is covered by focused regression tests.

