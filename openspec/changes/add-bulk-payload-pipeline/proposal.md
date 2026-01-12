# Change: Bulk Payload Streaming Pipeline

## Why
Large payloads (like sweep results) currently require custom chunking and forwarding logic.
We need a reusable, payload-agnostic pipeline so new gRPC-enabled services can stream
bulk data without bespoke implementations each time.

## What Changes
- Introduce a bulk payload streaming envelope for gRPC services (payload type/id,
  chunk metadata, encoding, schema version, and content hash).
- Add shared agent-side chunking utilities for any checker/service to stream payloads.
- Make the agent gateway payload-agnostic: forward chunks without decoding,
  enforce size limits, and buffer when core is unavailable.
- Add core-side reassembly and a handler registry keyed by payload type.
- Migrate sweep results to the new bulk payload pipeline as the first consumer.

## Impact
- Affected specs: edge-architecture
- Affected code: proto/monitoring.proto, pkg/agent, elixir/serviceradar_agent_gateway,
  elixir/serviceradar_core
