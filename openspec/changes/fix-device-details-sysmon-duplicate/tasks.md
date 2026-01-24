## 1. Implementation

- [x] 1.1 Modify `load_metric_sections/3` in `web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex` to exclude the "processes" section from `metric_sections` (do not call `build_process_section/3` or filter out its result)
- [x] 1.2 Verify that `process_metrics_section` component continues to render process metrics with the icon when `@sysmon_metrics_visible` is true
- [x] 1.3 Test device details page to confirm only one process card appears with the command-line icon (compiles cleanly, manual testing recommended)
