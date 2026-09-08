## Context
Relay-scoped analysis branches now emit bounded `camera_analysis_input.v1` envelopes and the platform can ingest normalized `camera_analysis_result.v1` payloads back into observability state. There is still no concrete adapter that moves those envelopes to an external worker implementation.

The first adapter should be operationally simple and easy to exercise from Python or other AI/CV stacks. HTTP is a reasonable first bridge because it is explicit, debuggable, and does not require a new cluster transport decision.

## Goals
- Deliver bounded camera analysis inputs to configured external workers over HTTP.
- Preserve relay session and worker provenance from dispatch through result ingestion.
- Keep dispatch bounded so viewer playback remains prioritized over analysis.
- Make room for future Boombox or non-HTTP adapters without changing the worker contract.

## Non-Goals
- Defining every future worker transport.
- Replacing the platform-local analysis branch model.
- Requiring synchronous object detection for every relay session.

## Decisions
### Use a reference HTTP adapter first
The platform will provide one concrete HTTP adapter first. It will accept `camera_analysis_input.v1`, POST it to a configured worker endpoint, and ingest successful result payloads through the existing normalized result ingestor.

### Keep dispatch bounded and lossy under pressure
Analysis dispatch should remain subordinate to viewer playback. The adapter must support bounded in-flight work, dispatch timeouts, and dropped-work telemetry rather than unbounded buffering.

### Preserve adapter pluggability
The adapter boundary should remain explicit so future Boombox, NATS, or direct process adapters can reuse the same worker input/output contract.

## Risks
### Worker latency can accumulate
Slow HTTP workers can build pressure quickly. The adapter must impose concurrency and timeout limits and shed analysis work before it affects relay stability.

### Result quality varies by worker
Worker responses may be partial or malformed. The adapter should normalize valid results and fail noisy or invalid responses explicitly.

### Too much transport specificity
The implementation must not leak HTTP assumptions into the analysis branch contract itself.
