# Change: Add reference camera analysis worker for HTTP adapter

## Why
The platform now has relay-scoped analysis branches, a normalized analysis contract, and a bounded HTTP worker adapter. What is still missing is a concrete worker implementation that proves the contract end to end and gives future analysis integrations a baseline to copy.

Without a reference worker, the adapter exists only as an infrastructure boundary. A small in-repo worker that accepts `camera_analysis_input.v1`, performs a deterministic derived-analysis step, and returns `camera_analysis_result.v1` will make the contract executable and testable.

## What Changes
- Add a small reference HTTP analysis worker that accepts `camera_analysis_input.v1` requests.
- Implement one deterministic analysis mode suitable for repeatable tests, such as keyframe gating and simple derived labels from input metadata.
- Provide an end-to-end test path from relay analysis branch through the HTTP adapter and back into normalized observability state.
- Document the worker as a reference implementation, not a production ML engine.

## Impact
- Affected specs:
  - `observability-signals`
  - `edge-architecture`
- Affected code:
  - `elixir/serviceradar_core_elx/**`
  - `elixir/serviceradar_core/**`
  - supporting test fixtures or a small worker app path to be determined
- Dependencies:
  - Builds on `add-camera-stream-analysis-egress`
  - Builds on `add-camera-analysis-http-worker-adapter`
