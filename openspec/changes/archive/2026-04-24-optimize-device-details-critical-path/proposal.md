# Change: Optimize device details critical-path loading

## Why
Some device details pages in `demo` are noticeably slow because the initial LiveView load fans out into a large set of synchronous SRQL and Ash reads, including data that is only needed for edit mode or non-active tabs.

## What Changes
- Reduce the default device details critical path by skipping edit-only and profile-only reads until the operator actually opens those surfaces.
- Scope discovery-job lookups to the device partition instead of scanning every mapper job.
- Parallelize independent sysmon presence and metric section probes to reduce wall-clock latency.
- Reduce LiveView longpoll fallback delay so a failed websocket upgrade does not add multi-second device-page mount latency in `demo`.

## Impact
- Affected specs: `build-web-ui`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex`
