# Tasks: Bulk Payload Streaming Pipeline

## 1. Protocol and Interfaces
- [ ] 1.1 Add bulk payload streaming envelope to `proto/monitoring.proto`
- [ ] 1.2 Generate updated protobufs for Go and Elixir
- [ ] 1.3 Define payload type registry and schema versioning conventions

## 2. Agent-Side Chunking
- [ ] 2.1 Implement shared chunker utility for byte-size chunking
- [ ] 2.2 Support optional compression and content hash generation
- [ ] 2.3 Wire streaming helper into agent service interface

## 3. Agent Gateway Forwarding
- [ ] 3.1 Add bulk payload stream handler in agent gateway
- [ ] 3.2 Enforce max chunk and max payload size limits
- [ ] 3.3 Buffer payloads in memory when core unavailable
- [ ] 3.4 Emit telemetry for forwarded, buffered, and dropped payloads

## 4. Core Reassembly and Dispatch
- [ ] 4.1 Implement payload reassembly keyed by `payload_id`
- [ ] 4.2 Validate payload hash and chunk completeness
- [ ] 4.3 Add handler registry keyed by `payload_type`
- [ ] 4.4 Emit processing metrics and error reporting

## 5. Sweep Migration
- [ ] 5.1 Migrate sweep results to bulk payload pipeline
- [ ] 5.2 Remove sweep-specific chunking in agent
- [ ] 5.3 Validate end-to-end sweep ingestion

## 6. Tests
- [ ] 6.1 Unit tests for chunker and reassembly
- [ ] 6.2 Gateway buffering tests
- [ ] 6.3 Core handler routing tests
- [ ] 6.4 Integration test for sweep results via bulk pipeline
