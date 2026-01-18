## 1. Log Details Attribute Parsing Fix

- [x] 1.1 Add `parse_attributes/1` helper to parse common attribute string formats
- [x] 1.2 Update `log_details/1` component to use parsed attributes
- [x] 1.3 Handle edge cases: already-parsed maps, JSON strings, key=value format
- [x] 1.4 Add fallback to raw string display for unparseable formats
- [ ] 1.5 Test with example log: `attributes={"error":"nats: no heartbeat"},resource={"service.name":"serviceradar-db-event-writer"}`

## 2. Promotion Rule Builder Component

- [x] 2.1 Create `components/promotion_rule_builder.ex` LiveComponent
- [x] 2.2 Implement form with match condition toggles:
  - [x] 2.2.1 Message body contains (text input)
  - [x] 2.2.2 Severity level (select dropdown)
  - [x] 2.2.3 Service name (text input, pre-filled)
  - [x] 2.2.4 Attribute equals (key-value pairs, addable)
- [x] 2.3 Add rule name field (required, auto-generated default)
- [x] 2.4 Add "auto-create alert" toggle (maps to rule.event.alert)
- [x] 2.5 Implement `build_match_map/1` to convert form state to LogPromotionRule.match
- [x] 2.6 Add form validation (name required, at least one condition enabled)

## 3. Log Details View Integration

- [x] 3.1 Add `can_create_rules?/1` helper to check operator/admin role
- [x] 3.2 Add "Create Event Rule" button (only visible if `can_create_rules?` returns true)
- [x] 3.3 Add modal/drawer container for rule builder
- [x] 3.4 Implement `handle_event("open_rule_builder", ...)` to extract log data and open modal
- [x] 3.5 Pass parsed log attributes to rule builder for pre-population
- [x] 3.6 Handle `{:rule_created, rule}` message to close modal and show success flash
- [ ] 3.7 Handle `{:rule_creation_failed, reason}` for error display

## 4. Rule Testing/Preview

- [x] 4.1 Implement `build_preview_query/1` to convert match conditions to SRQL query
- [x] 4.2 Add "Test Rule" button that triggers preview query
- [x] 4.3 Display match count ("N logs from the last hour would match")
- [x] 4.4 Display sample of matching logs (up to 10 entries) in compact table
- [x] 4.5 Add loading state during query execution
- [x] 4.6 Handle empty results ("No logs would match this rule")
- [x] 4.7 Add debouncing for auto-preview on condition changes (500ms delay)
- [x] 4.8 Add query timeout handling (5 second limit)

## 5. Rule Creation Backend Integration

- [x] 5.1 Add `handle_event("save_rule", ...)` to call `LogPromotionRule.create/1`
- [x] 5.2 Build event map with alert configuration (`%{alert: true/false}`)
- [x] 5.3 Handle authorization (user must have operator or admin role)
- [x] 5.4 Send parent message on success/failure

## 6. Rules UI Integration

- [x] 6.1 Update `rules_live/index.ex` Events tab to show more rule details (match conditions summary)
- [x] 6.2 Add edit link for LogPromotionRules (reuse promotion_rule_builder component)
- [x] 6.3 Enable "New Rule" button on Events tab to open rule builder without pre-population
- [x] 6.4 Add toggle enabled/disabled functionality for LogPromotionRules (like ZenRules)

## 7. Testing

Test files created:
- `test/serviceradar_web_ng_web/components/promotion_rule_builder_test.exs` - Unit tests
- `test/serviceradar_web_ng_web/live/log_live/show_test.exs` - LiveView RBAC tests
- Updated `test/serviceradar_web_ng_web/live/settings/rules_live_test.exs` - Rule builder tests

- [x] 7.1 Add test for attribute string parsing helper
- [x] 7.2 Add test for match map building from form state
- [x] 7.3 Add test for SRQL preview query building
- [x] 7.4 Add LiveView test for rule builder modal open/close
- [x] 7.5 Add LiveView test for rule preview functionality
- [x] 7.6 Add LiveView test for RBAC (viewer cannot see button, operator can)
- [ ] 7.7 Add integration test for full flow: view log → test rule → create rule → verify in settings UI

## 8. Documentation

- [x] 8.1 Add inline help text explaining match conditions
- [x] 8.2 Add help text explaining rule preview ("Tests against logs from the last hour")
- [ ] 8.3 Link to Rules settings page for advanced configuration
