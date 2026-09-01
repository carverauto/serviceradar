## 1. Route and controller
- [x] 1.1 Add `GET /api/v1/identity/resolve` taking an address, a partition and an
  optional MAC, returning the uid.
- [x] 1.2 Add `POST /api/v1/identity/resolve` taking the `devices` list shape that
  validation runs already accept.
- [x] 1.3 Call the existing resolver unchanged; do not reimplement its rules.
- [x] 1.4 Map its outcomes to distinct responses: resolved, malformed address, not found,
  ambiguous with candidates, MAC/IP conflict naming both.
- [x] 1.5 Report a batch per address, at 200, with each outcome identifying its input.
- [x] 1.6 Bound the batch and refuse an over-long one with the limit in the message.
- [x] 1.7 Refuse a batch entry carrying no address rather than dropping it, and coalesce a
  blank partition to the request's rather than to the global default.

## 2. Authorization
- [x] 2.1 Add an `identity.resolve` permission key beside `devices.facts.write`.
- [x] 2.2 Gate both routes on it.
- [x] 2.3 Default it to the roles that may already view the inventory, which reveal more
  than it does; keep it separate from `validation_runs.execute`.

## 3. Tests
- [x] 3.1 A known address resolves; a corroborating MAC is accepted; an unknown MAC is
  ignored.
- [x] 3.2 A MAC/IP conflict names both devices. Ambiguity is handled but **not tested**:
  an active device's address is unique and an identifier is unique per type/value/
  partition, so no state this suite can build reaches it.
- [x] 3.3 An unknown address is not found, not a server error; a malformed one is rejected.
- [x] 3.4 A mixed batch reports every outcome and does not fail as a whole.
- [x] 3.5 An over-long batch is refused with the limit stated; so is one holding an entry
  with no address.
- [x] 3.8 A blank partition falls back to the request's, and a blank request partition to
  the global default.
- [x] 3.6 Resolution requires the new permission and not validation-run execution.
- [x] 3.7 Resolving starts no probe and creates no validation run.

## 4. Documentation
- [x] 4.1 Document both routes in the API reference.
- [x] 4.2 Correct `device-facts.md`, which told a caller to start a validation run to
  learn the uid it needs before writing a fact.
- [x] 4.3 Note in `validation-runs.md` that identity resolution is separately available
  for callers that want an id and not a probe.

## 5. Confirm before building
- [x] 5.1 Batch bound is 128, matching the ceiling validation runs already apply.
- [x] 5.2 The response carries the uid and echoes ip and partition, nothing more.
