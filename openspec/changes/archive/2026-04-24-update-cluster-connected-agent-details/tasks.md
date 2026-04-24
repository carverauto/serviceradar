## 1. Connected agent metadata flow

- [x] 1.1 Update the connected-agent tracking/cache flow to retain runtime metadata needed by the cluster settings page, including version and platform details
- [x] 1.2 Ensure missing runtime metadata is represented explicitly so the UI can distinguish unknown values from stale or disconnected agents

## 2. Cluster settings UI

- [x] 2.1 Update the `/settings/cluster` "Connected Agents" card to display connected agent version, OS, architecture, and other relevant runtime details alongside existing status information
- [x] 2.2 Keep the layout readable for small and large fleets, including clear fallback text for unavailable metadata

## 3. Validation

- [x] 3.1 Add or update tests covering the connected-agent metadata shown on `/settings/cluster`
- [x] 3.2 Verify the cluster page continues to load when some agents omit version or platform metadata
