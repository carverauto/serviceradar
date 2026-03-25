# Camera Analysis Reference Worker

The camera analysis reference worker is a small HTTP service used to validate the platform-owned analysis contract end to end.

It is intentionally limited:
- it accepts `camera_analysis_input.v1`
- it returns deterministic `camera_analysis_result.v1`
- it derives findings from input metadata such as `keyframe`, `codec`, and `payload_format`

It is not a production object detector or CV pipeline. Its purpose is:
- executable documentation for the analysis worker contract
- a stable integration target for tests
- a baseline for future external workers

The current behavior is simple:
- supported keyframe H264 inputs return one deterministic derived finding
- non-keyframe or unsupported inputs return an empty result list
