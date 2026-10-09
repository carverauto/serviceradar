## ADDED Requirements

### Requirement: Cross-resource audit history surface

The system SHALL provide a Settings → Audit → History sub-page at `/settings/audit/history` gated by `settings.audit.view` that surfaces AshPaperTrail version rows from a configurable set of resources in a single time-ordered timeline. The list of in-scope resources MUST be readable from `config :serviceradar_core, ServiceRadar.Security.AuditHistory, resources: [...]` so operators can include or exclude specific resources without a code change.

The page MUST support filters for: resource type (from the configured allow-list), actor identifier, action type (`:create`, `:update`, `:destroy`), and a `since` / `until` time range. The page MUST honor each resource's existing AshPaperTrail policy when reading versions, so an operator who lacks the per-resource `settings.*.manage` capability does not see that resource's history rows.

The page MUST NOT offer mutating actions; revert / restore are out of scope.

#### Scenario: History renders versions across resources in time order
- **WHEN** an operator with `settings.audit.view` opens `/settings/audit/history` and the configured allow-list includes multiple resources that have version rows
- **THEN** the page lists those versions in `version_inserted_at` descending order, with each row labeled by its resource type

#### Scenario: Resource-type filter scopes the query to a single source
- **WHEN** the operator selects a single resource type from the filter
- **THEN** the query reads versions only from that resource's `*_versions` table

#### Scenario: Per-resource RBAC hides unauthorized rows
- **WHEN** an operator has `settings.audit.view` but lacks the per-resource read capability for a particular AshPaperTrail-enabled resource
- **THEN** that resource's version rows are absent from the page

### Requirement: AuditHistory module API

The system SHALL expose `ServiceRadar.Security.AuditHistory.list_recent/1` (and a companion `resources/0`) so the LiveView and any future caller can query the merged version timeline without duplicating the per-resource read logic. `list_recent/1` MUST accept the same filter set as the LiveView (`:resource_types`, `:actor_id`, `:action_types`, `:since`, `:until`, `:limit`, `:offset`) and MUST forward the current actor to each resource's `versions_read` action so per-resource RBAC stays in force.

#### Scenario: list_recent merges and re-sorts across the allow-list
- **WHEN** `AuditHistory.list_recent/1` is called with no filters and the allow-list contains multiple resources
- **THEN** the result is a list of `%{resource: module, version: struct}` rows ordered by the version's `version_inserted_at` desc, drawn from every resource in the allow-list

#### Scenario: actor_id filter narrows by actor across resources
- **WHEN** the caller passes `:actor_id`
- **THEN** each per-resource query filters by that actor before merging

### Requirement: Version detail diff view

The system SHALL render a per-version detail surface that displays the `changes` map as a key/value diff — `:from` and `:to` side by side for updates, snapshot for creates, and full attributes for destroys. Values larger than 8 KB serialized SHALL render with a "truncated" badge and an expand control; oversized payloads MUST NOT block the page render.

#### Scenario: Update version shows before / after
- **WHEN** the operator opens a version row with `action_type: :update`
- **THEN** each changed attribute is rendered with its prior and new value

#### Scenario: Large jsonb value is truncated
- **WHEN** a changed attribute's serialized value exceeds 8 KB
- **THEN** the diff shows a "truncated" badge and a byte-size label, not the inline JSON

## MODIFIED Requirements

### Requirement: Settings → Audit operator surface

The system SHALL provide a Settings → Audit section in the web-ng UI gated by `:audit_viewer` that exposes three sub-pages: **History** (the cross-resource AshPaperTrail timeline with resource-type, actor, action, and time-range filters and a diff view); **Events** (filterable, live-tailable `SecurityEvent` table with filters for kind, severity, actor, ip, route, and time range and CSV export); and **Lockouts** (list of locked accounts with an unlock action gated by `:security_admin`). The system MAY additionally expose a read-only **Rate Limits** panel showing current top-bucket pressure and recent denials.

#### Scenario: History page joins paper trail versions across resources
- **WHEN** an operator opens Settings → Audit → History
- **THEN** the page lists AshPaperTrail versions from every enabled resource in a single timeline, ordered by `inserted_at` descending, with filters that round-trip via the URL

#### Scenario: Events page supports filters and live tail
- **WHEN** an operator opens Settings → Audit → Events
- **THEN** the page renders the most recent events with active filters (kind, severity, actor, ip, route, time range) and subscribes to Phoenix.PubSub so newly recorded events appear at the top without a page refresh

#### Scenario: Unlock is gated by security_admin
- **WHEN** an operator with only `:audit_viewer` opens Settings → Audit → Lockouts
- **THEN** the Unlock control is disabled or hidden
- **AND WHEN** an operator with `:security_admin` clicks Unlock
- **THEN** the lockout is cleared and the operator's user_id is recorded on the AshPaperTrail version
