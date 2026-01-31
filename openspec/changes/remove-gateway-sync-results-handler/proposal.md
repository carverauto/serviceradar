# Change: Remove sync-specific handling in agent-gateway results routing

## Why
Sync results are currently handled differently than other gRPC result streams, which violates the intended gateway contract and complicates routing. Issue #2631 calls out the agent-gateway adding special handling for sync results; we want a single, consistent results path that reuses existing gRPC methods without extra gateway behavior.

## What Changes
- Remove sync-specific routing/logging/handler selection in agent-gateway.
- Ensure agents use the existing gRPC methods (`PushStatus` and `StreamStatus`) for status and chunked results uniformly.
- Ensure core results ingestion continues to handle sync results via the normal results pipeline once forwarded.

## Impact
- Affected specs: edge-architecture
- Affected code: agent-gateway status processor, agent results streaming, core results routing/ingestion
