## 1. Discovery
- [x] Review current `/services` LiveView queries and summary calculations.
- [x] Identify the current service identity key used for grouping status.

## 2. Design
- [x] Define service identity grouping (fields that make a service unique).
- [x] Confirm data source for status distribution by check.

## 3. Implementation
- [x] Update `/services` summary query to use latest status per service identity.
- [x] Add explicit "last updated" to summary header.
- [x] Remove gateways section from the page.
- [x] Replace service-type summary block with status distribution by check.
- [x] Ensure LiveView refreshes on status updates (PubSub + debounced refresh).

## 4. Validation
- [ ] Add/adjust tests for summary window filtering and widget rendering.
- [ ] Validate LiveView refresh updates counts without manual reload.
