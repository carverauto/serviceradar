## 1. Implementation
- [x] 1.1 Add log-pane live mode state to `LogLive.Index`, defaulting to disabled on initial load
- [x] 1.2 Add a header-level `Live` control for the logs pane and reflect the current mode in the UI
- [x] 1.3 Gate PubSub-driven log refreshes behind live mode and preserve manual pagination/query state when live mode is off
- [x] 1.4 Automatically pause live mode when the operator paginates or otherwise switches into manual browsing
- [x] 1.5 Add or update LiveView tests for default-off behavior, stable pagination, and explicit live-mode refreshes
