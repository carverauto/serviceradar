## Context
The camera analysis pipeline now has three important pieces:
- relay-scoped bounded analysis branches
- a normalized worker input/output contract
- a bounded HTTP adapter that can send work to external services

What it does not yet have is a concrete worker implementation that proves the adapter and result-ingestion contract in a realistic end-to-end path.

## Goals
- Add a simple reference worker that consumes `camera_analysis_input.v1`.
- Return deterministic `camera_analysis_result.v1` payloads so end-to-end tests are stable.
- Keep the worker lightweight and clearly non-production.

## Non-Goals
- Building a full object detection engine.
- Choosing a long-term ML serving architecture.
- Requiring this worker in production deployments.

## Decisions
### Keep the reference worker deterministic
The worker should derive outputs from existing input metadata, for example keyframe presence, codec, or payload format, so tests stay hermetic and explainable.

### Keep the worker transport-compatible with the current adapter
The worker should speak the same HTTP JSON contract already defined by the platform so it validates the existing adapter rather than introducing a new path.

### Treat the worker as executable documentation
This worker exists to prove and demonstrate the contract. It should be intentionally small and easy to read.

## Risks
### Confusing the reference worker with production analysis
The code and docs must make it explicit that this is a reference worker, not a real CV stack.

### Overfitting to the current adapter
The worker should validate the shared contract, not HTTP-only quirks.
