## Context
Camera relay sessions already centralize media ingest in `serviceradar_core_elx`. That is the correct place to branch media for additional consumers. Viewers are one consumer. Analysis workers are another.

The system needs to support processing such as object detection and scene analysis without forcing the agent to open another camera source session or forcing browsers to proxy analysis traffic. That means analysis should attach to the platform relay session, not to the edge camera directly.

## Goals
- Allow analysis to attach to an active relay session without creating duplicate upstream camera pulls.
- Support bounded frame/sample extraction suitable for AI and CV workloads.
- Provide a clean contract for returning detections or derived events into platform state.
- Keep viewer playback and analysis load independently observable.

## Non-Goals
- Replacing the existing relay ingest model.
- Standardizing one specific ML framework in this change.
- Requiring Boombox for all implementations.

## Architecture
### Analysis branches are relay-session-scoped
An analysis branch must attach to an existing relay session in `core-elx`. It should consume the same media source used for viewer fan-out and should not request a second camera pull from the agent.

### Analysis output is not raw media persistence
The primary output of analysis branches should be detections, events, sampled artifacts, or bounded derived data. This change is not about turning camera relay into an always-on raw video archive.

### Tooling remains pluggable
Boombox may be a useful bridge for handing raw media or frames to external processing systems, especially Python-based ones, but the platform contract should remain tool-agnostic:
- relay session source
- analysis tap policy
- worker input/output contract
- event ingestion path

### Boombox remains optional
The implementation should not require Boombox for every analysis path. The platform-owned branch manager, worker input envelope, and result ingestion contract must stand on their own so deployments can choose direct worker messaging, Boombox, or other external processing adapters without changing relay semantics.

## Risks
### Resource contention
Analysis work can easily starve viewer playback if it shares the same relay without bounded policies. The implementation must explicitly support rate limits, sampling intervals, and fan-out limits.

### Event noise
Object detection and scene analysis can emit large volumes of low-value events. The platform contract should bias toward normalized, bounded, and explainable outputs.

### Architecture drift
If analysis taps are allowed to bypass relay session state, the system will lose visibility into who is consuming a stream and why. Analysis consumers should remain first-class relay-attached entities.
