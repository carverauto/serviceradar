## 1. Implementation
- [x] 1.1 Reproduce the connected-agent metadata flapping path in `/settings/cluster` and confirm whether the live gateway tracker actually receives runtime metadata for affected agents.
- [x] 1.2 Extend the control-stream hello contract so agents send runtime metadata whenever they establish the live control channel.
- [x] 1.3 Update the gateway control-stream initialization path to track and persist that live runtime metadata without relying on registry backfill from the UI.
- [x] 1.4 Verify the cluster settings page still renders explicit unknown placeholders only when the live tracker truly lacks runtime metadata.
- [x] 1.5 Run targeted validation for the affected Go, gateway, and LiveView paths and update the change checklist to reflect reality.
