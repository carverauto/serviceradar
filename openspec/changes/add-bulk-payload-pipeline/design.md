# Design: Bulk Payload Streaming Pipeline

## Context
Sweep results and similar outputs can exceed single-message gRPC limits.
Today, each feature defines its own chunking logic and forwarding path.
We want a reusable, payload-agnostic pipeline for bulk data flowing
from edge services to core via the agent gateway.

## Goals / Non-Goals

**Goals:**
- Provide a generic, reusable bulk payload streaming protocol for gRPC-enabled services.
- Keep the agent gateway payload-agnostic while enforcing size limits and buffering.
- Centralize reassembly and dispatch in core with a handler registry by payload type.
- Migrate sweep results to validate the pipeline end-to-end.

**Non-Goals:**
- JetStream-based ingestion for these payloads (reserved for bulk collectors).
- Cross-tenant payload routing; all payloads remain tenant-scoped by mTLS identity.
- Durable buffering across gateway restarts (in-memory buffer only).

## Decisions

### 1. Bulk Payload Envelope
Define a gRPC streaming envelope that carries:
- `payload_type` (e.g., `sweep_results`, `snmp_bulk`)
- `payload_id` (UUID for reassembly and idempotency)
- `schema_version`
- `encoding` (e.g., `json`, `json+gzip`)
- `chunk_index`, `total_chunks`
- `content_hash` (hash of full payload)
- `metadata` (key/value map for routing context)
- `data` (chunk bytes)

This envelope is shared by any service sending bulk data.

### 2. Agent-Side Chunking Helper
Add a shared chunker utility that:
- Splits payloads to a max byte size
- Preserves chunk metadata
- Supports optional compression (e.g., gzip)
- Validates hash for the full payload

Services generate the payload once and stream via the helper.

### 3. Gateway Opaque Forwarding
The agent gateway:
- Accepts chunked payloads over gRPC
- Enforces max chunk size and max total size per payload
- Forwards chunks to core without decoding
- Buffers payloads in memory when core is unavailable

### 4. Core Reassembly + Dispatch
Core:
- Reassembles chunks by `payload_id`
- Validates `content_hash` and expected `total_chunks`
- Dispatches to a handler registry keyed by `payload_type`
- Records metrics for processing outcomes

## Risks / Trade-offs
- In-memory buffering can drop data if the gateway restarts.
- Extra CPU for hashing/compression on the agent.
- Requires careful schema versioning for payload evolution.

## Migration Plan
1. Add bulk payload streaming proto definitions.
2. Add agent chunking helper and wire into a generic streaming RPC.
3. Add gateway forwarding + buffering + telemetry.
4. Add core reassembly and handler registry.
5. Migrate sweep results to the new pipeline.

## Open Questions
- Should we support partial payload processing if some chunks are missing?
- What is the default max payload size across all services?
- Which payloads require compression by default?
