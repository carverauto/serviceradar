## 1. Implementation
- [x] 1.1 Inventory the current observability shell split across `LogLive.Index`, flows, BMP, BGP Routing, Camera Relays, and Camera Analysis Workers
- [x] 1.2 Extract or extend a shared observability shell component so all top-level observability panes render the same chrome and active-tab behavior
- [x] 1.3 Remove the flows-specific shell suppression and keep the shared shell visible when the flows pane is active
- [x] 1.4 Update BMP, BGP Routing, and Camera Relays to render inside the shared observability shell instead of bespoke top-level navigation blocks
- [x] 1.5 Move Camera Analysis Workers under Camera Relays as an explicit subsection while preserving direct links to the worker management surface
- [x] 1.6 Add or update LiveView coverage for direct-entry navigation, active-tab state, and camera-relay subsection routing
