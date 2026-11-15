## 1. Implementation
- [x] 1.1 Read add-on profile target queries a page at a time with an explicit page limit (`SRQLInputResolver.reduce_pages/4`).
- [x] 1.2 Replace the `Enum.take(max_targets)` cut with a count that stops one agent past the limit and refuses the profile whole.
- [x] 1.3 Report a refusal on the reconcile summary, by telemetry, by a warning logged on change, and in the add-on profile UI.
- [x] 1.4 Refuse saving an enabled profile whose target query selects more agents than its `max_targets`.
- [x] 1.5 Document the limit in `docs/docs/native-addons.md`.

## 2. Verification
- [x] 2.1 Reconciler regression: a profile over `max_targets` is refused whole and reported, its own assignments are disabled, and another profile's assignment on the same agent stays enabled.
- [x] 2.2 Reconciler regression: targets are read past the first SRQL page.
