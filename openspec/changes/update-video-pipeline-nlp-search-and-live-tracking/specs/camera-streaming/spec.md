## ADDED Requirements

### Requirement: Bounded live-frame tap for pure-Rust object tracking
The system SHALL allow live object detection and tracking pipelines to consume bounded decoded or IDR-sampled frames from an existing Core/recorder relay session (via `camera-streaming` analysis branch) or edge `retina` RTSP ingest without opening a second upstream connection to the camera.

#### Scenario: Live tracking attaches to active relay without opening a second camera session
- **WHEN** live object tracking is enabled for camera `cam-synth-0001` (`192.0.2.90`, `Gate North`) while live viewers or continuous recording already hold an upstream session
- **THEN** the platform SHALL tap bounded frames from that single existing upstream ingest
- **AND** SHALL NOT instruct `agent-edge-01` to open a second RTSP/RTSPS session to `192.0.2.10`

#### Scenario: Slow tracking consumer drops stale frames to protect relay and recording
- **WHEN** the stateful live tracker mailbox for a camera reaches its bounded capacity
- **THEN** the live-frame tap SHALL drop stale or excess frames with explicit drop metrics and SHALL preserve viewer WebRTC/WebSocket playback and NVR recording unaffected

### Requirement: Stateful live track publication over JetStream
The system SHALL publish live object detections, continuous `track_id` updates, and track lifecycle summaries from stateful tracking workers over NATS JetStream (`media.events.live_tracks.v1` on `CAMERA_LIVE_TRACKS`) with bounded latency budgets before optional Web-NG viewer overlay fanout, without mutating live or recorded media bytes.

#### Scenario: Live detections reach authorized viewer within latency budget
- **WHEN** a pure-Rust live tracking worker emits detections and `track_id` boxes for `drone-highway` or `drone-surf` within the configured latency budget
- **THEN** authorized active viewers SHALL receive non-destructive overlay updates over PubSub/channel transport while JetStream retains the bounded track-event stream
- **AND** detections exceeding the latency budget SHALL NOT be rendered late on live video
