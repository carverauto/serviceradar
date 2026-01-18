# Change: Add Log-to-Event UI

## Why

Users viewing log details need an easy way to create event promotion rules directly from a specific log entry. The current workflow requires navigating to Settings > Rules, understanding the LogPromotionRule schema, and manually crafting match conditions. This friction prevents users from quickly acting on interesting logs.

Additionally, the log details view does not properly parse structured attributes from the log entry, making it difficult to see key metadata fields that could be used for matching.

## What Changes

### Log Details View Enhancements
- **Attribute parsing**: Parse the `attributes` field (often stored as a JSON string like `attributes={"error":"..."}, resource={...}`) into structured key-value display
- **"Create Event Rule" action**: Add a button that opens a simple rule builder modal pre-populated from the current log

### Simple Promotion Rule Builder
- **Focused UI**: A modal/drawer form specifically for creating `LogPromotionRule` records, NOT the full JDM/Zen rule editor
- **Auto-populated fields**: Pre-fill match conditions from the current log (message body, severity, service name, attributes)
- **Match condition builder**: Simple form fields for:
  - Message body contains (case-insensitive substring)
  - Severity level (select or checkbox group)
  - Service name (text input or dropdown)
  - Attribute equals (key-value pairs)
- **Event configuration**: Basic event settings (rule name, description, whether to auto-create alerts)

### Rule Testing/Preview
- **Test against recent logs**: Before saving, users can preview how many logs from a recent time window would match the rule
- **Sample matched logs**: Show a sample of matching log entries so users can verify the rule is correct
- **Live updates**: As users toggle conditions on/off, the preview updates to show the impact

### Log Parsing Fix
- Handle the common pattern where `attributes` is a semicolon or comma-delimited string of key=value pairs
- Display parsed attributes as individual rows in the "Additional Metadata" section

## Data Flow: LogPromotionRule Lifecycle

Understanding the end-to-end flow is critical for this feature:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. USER CREATES RULE (this feature)                            │
│    Log Details View → Rule Builder Modal → LogPromotionRule    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. RULE STORED IN CNPG                                         │
│    Table: log_promotion_rules (tenant-scoped via search_path)  │
│    Fields: name, enabled, priority, match (conditions), event  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. LOG PROMOTION PIPELINE (automatic, on log ingestion)        │
│    ServiceRadar.Observability.LogPromotion.promote([logs])     │
│    • Load active LogPromotionRules (priority-ordered)          │
│    • Match log against rules (body_contains, severity, etc.)   │
│    • Build OCSF event from matched rule                        │
│    • Insert to ocsf_events table                               │
│    • Optionally create alert (if severity >= high or explicit) │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. RULE VISIBLE IN SETTINGS UI                                 │
│    /settings/rules?tab=events shows all LogPromotionRules      │
│    Admin can edit, toggle, or delete rules there               │
└─────────────────────────────────────────────────────────────────┘
```

**Important**: This uses `LogPromotionRule`, NOT `ZenRule`. They are separate mechanisms:
- **ZenRule**: Message normalization via GoRules JDM, synced to NATS KV, processed by zen-consumer (Rust)
- **LogPromotionRule**: Log-to-OCSF-event conversion, processed by Elixir `LogPromotion` pipeline (no KV sync needed)

## RBAC Requirements

- **"Create Event Rule" button**: Only visible to users with `operator` or `admin` role
- **LogPromotionRule.create action**: Already enforces operator/admin via Ash policies
- **Viewers**: Can see log details but cannot create rules
- **Rules UI integration**: Rules created from log details appear in `/settings/rules?tab=events` where admins can further edit them

## Impact

- **Affected specs**: `observability-rule-management`
- **Affected code**:
  - `web-ng/lib/serviceradar_web_ng_web/live/log_live/show.ex` - Add action button (RBAC-gated) and fix attribute parsing
  - `web-ng/lib/serviceradar_web_ng_web/components/promotion_rule_builder.ex` - New simple rule builder component
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/rules_live/index.ex` - Enable "New Rule" button for Events tab (currently disabled)

## Out of Scope

- Full JDM/Zen rule editor integration (deliberately avoiding complexity)
- Alert configuration UI (mentioned as future work in issue)
- Bulk rule creation from multiple logs
