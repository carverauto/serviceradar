## 1. Implementation
- [x] 1.1 Update sweep scheduling change to detect missing Oban instance and return a non-fatal warning instead of raising.
- [x] 1.2 Add reconciliation to schedule enabled sweep groups once Oban is available (on startup or periodic job).
- [x] 1.3 Expose deferred-scheduling warning in Settings > Networks when a sweep group is saved.
- [x] 1.4 Add tests covering sweep group creation without Oban and reconciliation when Oban becomes available.
