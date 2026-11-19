# Storage Entitlements and NVR Recording Health

Full-stack ServiceRadar Solution Pack (`io.serviceradar.storage-and-nvr-health`) monitoring SaaS archive storage entitlement utilization, PD5 investigation hold-pin budget share, S3 archive role credential and daily usage report health, and continuous camera recording silence.

## Included Resources

### Declarative Posture Checks (4)
- `storage-entitlement-utilization` -- Evaluates `storage.entitlement_utilization` against warning and critical billable utilization thresholds and hard-cap state.
- `storage-hold-pin-pressure` -- Evaluates `storage.hold_pin_pressure` to detect active investigation holds starving normal object retention.
- `storage-archive-credential-health` -- Evaluates `storage.archive_credential_and_usage_health` for S3 writer/reader/retention credential health and daily usage report freshness.
- `camera-continuous-recording-silence` -- Evaluates `camera.continuous_recording_silence` across enabled continuous recording policies.

### Stateful Alert Rules (2)
- `storage_entitlement_hard_cap` -- Opens a high-priority alert when storage entitlement hard-cap or critical utilization transitions to down.
- `camera_continuous_recording_silence` -- Opens a high-priority alert when an enabled continuous camera recording policy seals zero blocks across the configured window.

### Authored Dashboards (1)
- `storage-and-nvr-overview` -- Unified SRQL overview dashboard tracking posture check availability, silent camera policy alerts, and storage health transitions.
