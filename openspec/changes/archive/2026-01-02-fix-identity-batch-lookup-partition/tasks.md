## 1. Database Layer
- [x] 1.1 Update `BatchGetDeviceIDsByIdentifier` to accept a `partition` parameter
- [x] 1.2 Add `AND partition = $3` to `batchGetDeviceIDsByIdentifierSQL`
- [x] 1.3 Update DB interface and gomock mocks/callers for the new signature

## 2. Identity Engine
- [x] 2.1 Group batch updates by partition (defaulting empty to `default`)
- [x] 2.2 For each partition: batch query strong identifiers by type using the partition-aware DB API
- [x] 2.3 Map identifier hits back to updates using the existing strong-ID priority order

## 3. Tests
- [x] 3.1 Add regression test: two partitions with the same MAC in the same batch resolve to different device IDs
- [x] 3.2 Update existing tests/mocks that expect `BatchGetDeviceIDsByIdentifier` calls
- [x] 3.3 Run `go test ./pkg/registry/...` and `go test ./pkg/db/...`

## 4. Validation
- [x] 4.1 Run `openspec validate fix-identity-batch-lookup-partition --strict`
