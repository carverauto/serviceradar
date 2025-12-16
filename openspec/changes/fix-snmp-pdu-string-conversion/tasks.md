## 1. Fix
- [x] 1.1 Update SNMP PDU conversion for `gosnmp.OctetString` and `gosnmp.ObjectDescription` to decode `[]byte` into `string` without panicking
- [x] 1.2 Ensure conversion returns an error (not a panic) when `variable.Value` is not the expected Go type for `OctetString`/`ObjectDescription`

## 2. Tests
- [x] 2.1 Add a regression test for `convertVariable()` converting `OctetString` values returned as `[]byte`
- [x] 2.2 Add a regression test for `convertVariable()` converting `ObjectDescription` values returned as `[]byte`
- [x] 2.3 Add a regression test that an unexpected `Value` type for these string ASN.1 types returns an error and does not panic

## 3. Validation
- [x] 3.1 Run `go test ./pkg/checker/snmp/...`
- [x] 3.2 Run `make lint`
- [x] 3.3 Run `openspec validate fix-snmp-pdu-string-conversion --strict`
