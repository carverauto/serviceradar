# Camera Semantic Search Health

First-party ServiceRadar Solution Pack (`io.serviceradar.camera-semantic-search-health`) monitoring camera visual indexing job backlog via SRQL and probing `media-worker` `/readyz` readiness endpoints.

## Included Resources

### Declarative Checks (2)
- `visual-index-queue-lag` -- Core `srql_query` check monitoring queued visual indexing job backlog against configurable warning and critical thresholds.
- `media-worker-readiness` -- Edge `http_request` check probing the `media-worker` `/readyz` endpoint (`service_targets` -> `extract_field` -> `threshold_assert` -> `alert_output`).

### Stateful Alert Rules (2)
- `camera_visual_index_queue_lag` (`enabled`) -- Opens a high-priority alert when visual indexing backlog exceeds the critical threshold.
- `camera_media_worker_unready` (`enabled`) -- Opens a critical alert when the `media-worker` readiness probe transitions to `down`.

### Authored Dashboards (1)
- `camera-semantic-search-overview` -- Unified SRQL overview dashboard tracking semantic indexing pipeline availability, failing media worker probes, and open pipeline alerts.
