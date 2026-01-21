## Context

Users can view individual log entries in the observability dashboard (`/observability/logs/:log_id`). When they see an interesting or problematic log, they often want to:
1. Understand the full log context (attributes, metadata)
2. Create a rule to promote similar logs into events for alerting

The existing `LogPromotionRule` Ash resource provides exactly the right abstraction for this - it's simpler than Zen/JDM rules and maps directly to the "log → event" use case. However, there's no direct UI path from viewing a log to creating a promotion rule.

The log details view also has a display issue: attributes are sometimes stored as a serialized string (e.g., `attributes={"error":"..."}, resource={...}`) rather than a parsed JSON object, causing the UI to show the raw string instead of structured fields.

## Goals / Non-Goals

**Goals:**
- Enable users to create event rules directly from log details view
- Provide a simple, focused form (not a visual rule editor)
- Fix attribute display to show structured metadata
- Pre-populate form with values from the current log
- Test rules against recent logs before saving
- Integrate with existing Rules UI at `/settings/rules?tab=events`

**Non-Goals:**
- Replace or integrate with the full JDM/Zen rule editor
- Support complex rule logic (multiple conditions with AND/OR)
- Build alert configuration UI (future scope)

## Decisions

### Decision: Use LogPromotionRule, Not Zen Rules

**What:** The simple rule builder will create `LogPromotionRule` records, not `ZenRule` records.

**Why:**
- `LogPromotionRule` is designed exactly for log-to-event promotion
- Match conditions are simple maps (`body_contains`, `severity_text`, etc.)
- No JDM compilation required - rules work immediately
- Existing `LogPromotion` pipeline handles execution automatically
- Zen rules are for complex transformation logic, overkill for simple matching

### Decision: Modal-Based Form, Not Separate Page

**What:** The rule builder opens as a modal overlay from the log details page.

**Why:**
- User maintains context of the log they're acting on
- No navigation away from the log details
- Simpler implementation - can pass log data directly
- Consistent with other quick-action patterns in the UI

### Decision: RBAC via Role Check in UI + Ash Policies

**What:** The "Create Event Rule" button is only rendered for users with `operator` or `admin` role. Backend enforcement via Ash policies.

**Why:**
- Viewers should be able to see logs but not create rules that affect the system
- Consistent with existing RBAC pattern (e.g., device editing restricted to admins)
- Defense in depth: UI hides button + Ash policy enforces at action level

**Implementation:**
```elixir
# In log_live/show.ex - check role before rendering button
defp can_create_rules?(%{user: %{role: role}}) when role in [:operator, :admin], do: true
defp can_create_rules?(_), do: false

# In template
<.ui_button :if={can_create_rules?(@current_scope)} ...>
  Create Event Rule
</.ui_button>
```

### Decision: Integration with Existing Rules UI

**What:** Rules created from log details appear in `/settings/rules?tab=events` and can be edited there.

**Why:**
- Single source of truth for all LogPromotionRules
- Admins can adjust priority, add conditions, or disable rules
- No need to build a separate rule editing UI

**Currently:** The "New Rule" button on the Events tab is disabled. This change enables:
1. Creating rules from log details (primary flow)
2. Optionally enabling the "New Rule" button in settings for direct creation

### Decision: Attribute Parsing with Fallback

**What:** Parse common attribute serialization formats but fall back to raw display.

**Why:**
- Logs come from various sources with inconsistent serialization
- Common patterns: `key=value,key2=value2` or `key={"nested":"json"},key2=...`
- Must not break on unexpected formats
- Display raw string if parsing fails (current behavior as fallback)

### Decision: Rule Testing via SRQL Preview Query

**What:** Before saving a rule, users can test it against recent logs using SRQL queries.

**Why:**
- Users need confidence that their rule will match the intended logs
- Seeing sample matches helps catch overly broad or narrow conditions
- SRQL already supports the filtering needed (body contains, severity, service name)
- Preview is read-only and doesn't affect the system

**Approach:**
- Build an SRQL query from the enabled match conditions
- Query logs from the last hour (configurable time window)
- Display count of matching logs and a sample (5-10 entries)
- Update preview as conditions change (debounced to avoid excessive queries)

## Technical Approach

### Attribute String Parsing

```elixir
# Pattern: "attributes={\"error\":\"nats: no heartbeat\"},resource={\"service.name\":\"foo\"}"
# Should parse into:
%{
  "attributes" => %{"error" => "nats: no heartbeat"},
  "resource" => %{"service.name" => "foo"}
}
```

Parser will:
1. Check if value is already a map (no parsing needed)
2. Try to decode as JSON
3. Try to parse `key={json},key2={json}` format
4. Try to parse `key=value,key2=value2` format
5. Fall back to displaying raw string

### Rule Builder Form Fields

```
┌─────────────────────────────────────────────────────────────┐
│ Create Event Rule from Log                              [X] │
├─────────────────────────────────────────────────────────────┤
│ Rule Name: [_______________________________]                │
│                                                             │
│ Match Conditions (from this log):                          │
│                                                             │
│ ☑ Message contains: [Fetch error_____________]             │
│   (case-insensitive substring match)                       │
│                                                             │
│ ☑ Severity: [ERROR ▼]                                      │
│                                                             │
│ ☐ Service name: [serviceradar-db-event-writer]             │
│                                                             │
│ ☐ Attribute match:                                         │
│   Key: [error__________] Value: [nats: no heartbeat...]    │
│                                                             │
│ Event Options:                                             │
│ ☑ Auto-create alert for matching events                    │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ Rule Preview                              [Test Rule]       │
│                                                             │
│ ✓ 47 logs from the last hour would match this rule         │
│                                                             │
│ Sample matches:                                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ 07:42:06 ERROR  Fetch error                             │ │
│ │ 07:38:12 ERROR  Fetch error                             │ │
│ │ 07:35:01 ERROR  Fetch error                             │ │
│ │ 07:31:45 ERROR  Fetch error                             │ │
│ │ 07:28:33 ERROR  Fetch error                             │ │
│ └─────────────────────────────────────────────────────────┘ │
│                                                             │
│                               [Cancel]  [Create Rule]       │
└─────────────────────────────────────────────────────────────┘
```

### Match Condition Mapping

| UI Field | LogPromotionRule.match key | Source from Log |
|----------|---------------------------|-----------------|
| Message contains | `body_contains` | `log.body` or `log.message` |
| Severity | `severity_text` | `log.severity_text` |
| Service name | `service_name` | `log.service_name` |
| Attribute match | `attribute_equals` | Parsed `log.attributes` |

### Component Structure

```
log_live/show.ex
├── render/1 - Add "Create Event Rule" button to header actions
├── handle_event("open_rule_builder", ...) - Open modal with log data
└── handle_info({:rule_created, rule}, ...) - Handle success, show flash

components/promotion_rule_builder.ex (new)
├── mount/1 - Receive log data, parse attributes
├── render/1 - Form with match condition checkboxes and fields
├── handle_event("toggle_condition", ...) - Enable/disable conditions
├── handle_event("test_rule", ...) - Execute preview query
├── handle_event("save", ...) - Create LogPromotionRule via Ash
├── build_match_map/1 - Convert form state to rule match map
└── build_preview_query/1 - Convert match conditions to SRQL query
```

### Rule Preview Query Building

Convert enabled match conditions to SRQL query:

```elixir
def build_preview_query(match_conditions) do
  filters = []

  # Message body contains
  filters = if match_conditions.body_contains do
    [~s(body:"*#{escape(match_conditions.body_contains)}*") | filters]
  else
    filters
  end

  # Severity
  filters = if match_conditions.severity_text do
    [~s(severity_text:"#{match_conditions.severity_text}") | filters]
  else
    filters
  end

  # Service name
  filters = if match_conditions.service_name do
    [~s(service_name:"#{match_conditions.service_name}") | filters]
  else
    filters
  end

  # Build final query with time range
  base = "in:logs"
  time_filter = "timestamp:>now-1h"

  [base, time_filter | filters]
  |> Enum.join(" ")
  |> Kernel.<>(" limit:10")
end
```

Preview response structure:
```elixir
%{
  match_count: 47,
  sample_logs: [
    %{timestamp: ~U[...], severity_text: "ERROR", body: "Fetch error"},
    # ... up to 10 samples
  ],
  query_time_ms: 45
}
```

## Risks / Trade-offs

### Risk: Attribute parsing may fail on edge cases
**Mitigation:** Always fall back to raw string display. Add logging for parse failures to identify common patterns to support.

### Risk: Users may create overlapping rules
**Mitigation:** Show a warning if a rule with similar match conditions exists. Future: add rule priority UI.

### Risk: Form may be too simple for power users
**Mitigation:** Include link to full Rules settings page for advanced configuration. This UI is for the common case.

### Risk: Preview queries may be slow or resource-intensive
**Mitigation:**
- Limit preview to last 1 hour of logs (configurable)
- Cap sample results at 10 entries
- Use debouncing to avoid queries on every keystroke
- Show loading state during query execution
- Add query timeout (5 seconds)

## Migration Plan

No database migrations required - uses existing `log_promotion_rules` table.

Deployment:
1. Deploy web-ng changes (attribute parsing, rule builder modal)
2. No backend changes needed - existing LogPromotionRule actions suffice

Rollback:
- Remove modal and button if issues arise
- Attribute parsing fallback means display always works

## Open Questions

1. **Should we validate for duplicate rules?** If a rule with the same `body_contains` value exists, warn or prevent creation?

2. **Priority field exposure?** The `LogPromotionRule` has a `priority` field (default 100). Should the simple builder expose this or always use default?

3. **Preview time window?** Default is 1 hour. Should users be able to select different time ranges (15 min, 1 hour, 24 hours)?
