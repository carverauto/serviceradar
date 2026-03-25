# Change: Add HTTP worker adapter for camera analysis branches

## Why
The camera analysis egress work now defines relay-scoped analysis branches, a normalized worker input envelope, and normalized result ingestion. What is still missing is a concrete adapter that can take bounded analysis inputs and deliver them to an external worker implementation.

The next useful step is a simple, explicit adapter that external Python/CV services can consume without changing the relay pipeline or forcing Boombox adoption. An HTTP JSON adapter is the smallest concrete bridge that exercises the contract end to end.

## What Changes
- Add a configurable HTTP worker adapter in `serviceradar_core_elx` for delivering `camera_analysis_input.v1` payloads to external analysis workers.
- Add bounded dispatch behavior so worker delivery remains subordinate to relay/viewer playback and analysis branch limits.
- Ingest successful worker responses through the existing camera analysis result contract and observability ingestion path.
- Add telemetry for dispatch success, failure, timeout, and dropped work.
- Keep the platform contract tool-agnostic; this is a reference adapter, not a requirement that all analysis workers be HTTP services.

## Impact
- Affected specs:
  - `camera-streaming`
  - `observability-signals`
  - `edge-architecture`
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
- Dependencies:
  - Builds on `add-camera-stream-analysis-egress`
  - Compatible with future Boombox-backed or non-HTTP worker adapters
