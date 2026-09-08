## 1. Implementation

- [x] 1.1 Define the incident fingerprint and default grouping policy for event-derived alerts, including the initial Falco/security defaults
- [x] 1.2 Update the event-derived alert path to create or update a single active incident instead of creating duplicate alert rows
- [x] 1.3 Record duplicate occurrence metadata on the active incident and preserve event provenance for operator inspection
- [x] 1.4 Suppress repeated immediate notification attempts for duplicate events inside cooldown while preserving renotify behavior for sustained incidents
- [x] 1.5 Extend the rules UI and backing resources to expose grouping, cooldown, and renotify knobs for event-derived alerts
- [x] 1.6 Add backend and UI tests covering repeated Falco critical events, cooldown behavior, and configurable grouping keys
- [x] 1.7 Document the new incident-based behavior and default Falco/security alert policy
