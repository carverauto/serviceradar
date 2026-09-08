## Context

Every AshPaperTrail-enabled resource in serviceradar already
writes to its own `*_versions` table on every create/update/
destroy. The list — across credentials, ansible, edge, and the
new `AuthLockout` — is committed to the resource definitions in
`elixir/serviceradar_core/lib/serviceradar/`. No cross-resource
read surface exists; the Settings → Audit section in web-ng has
Events and Lockouts sub-pages but the History sub-page documented
in the original proposal was deferred.

The reason for the deferral was the query shape: AshPaperTrail
gives you `Resource.versions_read` per resource, not a
cross-resource union. Each `*_versions` table has its own
schema (different `changes` shapes, different action sets), and
the actor / route attribution lives in
`version_action_inputs` jsonb rather than a typed column.

## Goals / Non-Goals

**Goals**

- Operators can see a unified timeline of who changed which
  AshPaperTrail-enabled resource and what changed.
- Filters narrow by resource type, actor identifier, action type
  (`:create` / `:update` / `:destroy`), and time range.
- A single-version detail view renders the `changes` map as a
  before/after diff (or, for create/destroy, the full attribute
  snapshot).
- No new RBAC capability; reuse `settings.audit.view`.

**Non-Goals**

- Live-tailing version events via PubSub. Versions are
  low-frequency; refresh-on-demand is sufficient.
- A separate "change index" table or materialized view. The
  per-resource version tables are already indexed on
  `version_inserted_at`; the cross-resource merge happens in
  Elixir at query time.
- Mutating actions on the History page (e.g. "revert this
  version"). The page is strictly read-only.
- Free-text search over `changes` jsonb content. Filterable
  metadata fields (actor / kind / time) are sufficient for v1.

## Decisions

### D1. Cross-resource read via per-resource queries + Elixir merge

`ServiceRadar.Security.AuditHistory.list_recent/1` iterates the
configured resource list, runs each resource's
`Resource.versions_read` action with the user-supplied filters
(actor_id, action_type, time range; resource-type filter prunes
the list before the loop), then merges and re-sorts the union by
`version_inserted_at` desc. Pagination is offset-based:
`{:offset, integer}` opt with `:limit` (default 50). Across-source
offset is "skip N from the merged stream"; for the page sizes
operators actually use (≤ 200) this is fine.

Per-resource queries run sequentially in v1; if the merged-sort
phase becomes the bottleneck we can spawn one Task per resource
and wait on them. The DB has the work either way.

### D2. The resource allow-list lives in app config

`config :serviceradar_core, ServiceRadar.Security.AuditHistory,
resources: [...]` is the canonical list. Default ships with every
AshPaperTrail-enabled resource. The list is a config knob, not a
resource discovery loop, so operators can:

- exclude high-write-volume resources from the default view
  (e.g. `PlaybookRun` versions during a busy ansible run);
- add a new AshPaperTrail-enabled resource to history coverage
  without a code change to `AuditHistory`.

The LiveView's filter UI also offers a resource-type selector
sourced from this list.

### D3. Version detail rendering

For the per-version detail view we render `changes` as a
two-column key/value diff using `Phoenix.Component`. The shape
of `changes` is documented in AshPaperTrail as
`%{attribute_name => %{from: term, to: term}}`. For `:create`
the `from` side is nil; for `:destroy` the row is the full
snapshot of the attributes at destroy time. Both cases render
sensibly with the same component.

Action inputs (`version_action_inputs`) are shown below the
diff for context. Actor attribution is pulled from
`version_action_inputs[:actor]` when present.

### D4. Authorization

The page is gated by `settings.audit.view` at the LiveView
`mount/3` (same pattern as the Events and Lockouts pages). The
per-resource `versions_read` actions are gated by each resource's
own policy; in practice the existing `ServiceRadar.Policies`
helpers grant version reads to actors with the relevant
`settings.*.manage` permission. The AuditHistory module passes
the LiveView's `current_scope` actor through to each resource
read, so per-resource RBAC stays in force — an operator who can
see the audit page but lacks credentials manage permission will
see the rest of the history but not credential versions.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Elixir-side merge cost grows with resource list × page size | Allow-list lets operators trim high-volume resources; default page size 50. If a deployment has 9 enabled resources × 50 versions = 450 rows to merge — trivial. |
| Filter-by-actor is jsonb lookup (`changes->>'actor'`) → no index | AshPaperTrail tags the `version_action_inputs` with the actor at write time; an explicit index can be added in a follow-up if filter latency becomes an issue. v1 accepts the tablescan within the page window. |
| New AshPaperTrail-enabled resources don't auto-appear | Allow-list is the source of truth; adding a resource is a one-line config diff. Documented in the operator runbook. |
| The diff component renders large jsonb payloads (e.g. ansible playbook content) inline | Show a "truncated" badge with byte size when a value exceeds 8 KB; click expands. v1 ships with the truncation marker; full lazy load is a follow-up. |
| Per-resource RBAC may produce a sparse history for unprivileged operators | This is desired behavior — operators see only the versions they're authorized to read. Pagination still feels normal because pages skip past hidden rows. |

## Migration Plan

1. Land the `AuditHistory` module + tests.
2. Land the LiveView + nav update + route.
3. Operator runbook gets a paragraph on the new page and the
   resource allow-list.
4. (Optional, follow-up.) Drop `resources:` config defaults to
   exclude any resource an operator complains about.

## Open Questions

1. Should the "actor" filter accept both user_id and email? The
   `version_action_inputs` shape varies by resource — some
   resources stamp `actor: %{id: ...}`, others `actor: %{email: ...}`.
   Leaning toward "either; we OR them at query time."
2. Should we surface AshPaperTrail's `belongs_to_actor` linkage
   (which makes the actor a proper FK) and gradually retrofit
   resources onto it? Out of scope for this change; tracked as a
   follow-up question.
