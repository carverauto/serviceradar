## 1. Data Model
- [ ] 1.1 Add migrations for authored dashboards, panels, report schedules, and report deliveries in the `platform` schema.
- [ ] 1.2 Add Ash resources/actions for authored dashboards with create, update, archive/delete, read, list, and ownership/visibility fields.
- [ ] 1.3 Add Ash resources/actions for dashboard panels with SRQL query text, visual type, visual config, layout, and refresh metadata.
- [ ] 1.4 Add Ash resources/actions for report schedules and delivery history with due-time tracking and idempotent state transitions.
- [ ] 1.5 Add reusable Identity user groups/memberships and dashboard access grants for private/shared/public dashboard visibility.

## 2. SRQL Preview and Visual Compatibility
- [ ] 2.1 Build a bounded SRQL preview/introspection context that applies preview limits and returns rows plus field metadata.
- [ ] 2.2 Implement a visual registry that declares required field shapes and validates panel visual configs.
- [ ] 2.3 Add backend validation so saved panels have valid SRQL, compatible visual config, and bounded refresh/report settings.
- [ ] 2.4 Add tests for query preview success, invalid SRQL, unsupported visual mappings, and table fallback.

## 3. Dashboard Creator UI
- [ ] 3.1 Add an Analytics dashboards workspace for listing saved dashboards and creating a new dashboard.
- [ ] 3.2 Add a dashboard editor with SRQL query input, preview execution, field metadata display, visual picker, and panel config.
- [ ] 3.3 Add layout editing for multiple panels with stable ordering and responsive rendering.
- [ ] 3.4 Add saved dashboard show route at `/dashboard/:dashboard_id` without changing `/dashboard` or `/dashboards/:route_slug`.
- [ ] 3.5 Add share/copy-link affordances and clear owner/visibility labels.

## 4. Scheduled Reports
- [ ] 4.1 Add a dashboard report schedule form with recipients, timezone, cadence/cron, enabled state, and next-run preview.
- [ ] 4.2 Add one periodic scheduler job that finds due enabled schedules and enqueues per-due delivery jobs.
- [ ] 4.3 Add an idempotent delivery worker that renders a bounded dashboard snapshot and sends email through existing mailer infrastructure.
- [ ] 4.4 Persist delivery history with success/failure status, retry metadata, and operator-visible errors.
- [ ] 4.5 Add tests covering due schedule scan, duplicate prevention, successful delivery, failure recording, and disabled schedules.

## 5. Permissions and Navigation
- [ ] 5.1 Add permissions for viewing, creating, editing, deleting, sharing, and scheduling authored dashboards.
- [ ] 5.2 Add permissions for managing reusable user groups and viewing share principals.
- [ ] 5.3 Decide and implement Analytics navigation placement without polluting the existing settings/sidebar structure.
- [ ] 5.4 Ensure dashboard package management remains under Settings -> Dashboards and does not mix with authored dashboard CRUD.

## 6. Validation
- [ ] 6.1 Run focused Ash/resource tests for dashboard resources and report jobs.
- [ ] 6.2 Run focused LiveView tests for creator, editor, saved dashboard display, and report schedule workflows.
- [ ] 6.3 Run `mix format` and relevant web-ng quality checks.
- [ ] 6.4 Run `openspec validate add-dashboard-creator --strict`.
