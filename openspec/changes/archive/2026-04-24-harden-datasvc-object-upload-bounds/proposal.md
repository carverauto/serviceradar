# Change: Harden Datasvc Object Upload Bounds

## Why
`go/pkg/datasvc` accepts client-streamed object uploads and writes them into JetStream object storage, but it does not enforce a cumulative per-object size limit and it creates the object-store bucket without a storage cap. An authenticated writer can therefore exhaust JetStream storage through a single long upload or repeated oversized uploads.

## What Changes
- add an explicit service-side cumulative upload ceiling for `UploadObject`
- apply an explicit JetStream object-store capacity cap instead of leaving the object bucket unbounded
- define the bounded-upload/storage contract in OpenSpec and cover it with focused tests

## Impact
- Affected specs: `data-service-storage`
- Affected code:
  - `go/pkg/datasvc/server.go`
  - `go/pkg/datasvc/nats.go`
  - `go/pkg/datasvc/config.go`
  - `go/pkg/datasvc/types.go`
  - `go/pkg/datasvc/*_test.go`
