## 1. Data Model
- [x] 1.1 Add migrations for authored dashboards, panels, report schedules, and report deliveries in the `platform` schema.
- [x] 1.2 Add Ash resources/actions for authored dashboards with create, update, archive/delete, read, list, and ownership/visibility fields.
- [x] 1.3 Add Ash resources/actions for dashboard panels with SRQL query text, visual type, visual config, layout, and refresh metadata.
- [x] 1.4 Add Ash resources/actions for report schedules and delivery history with due-time tracking and idempotent state transitions.
- [x] 1.5 Add reusable Identity user groups/memberships and dashboard access grants for private/shared/public dashboard visibility.

## 2. SRQL Preview and Visual Compatibility
- [x] 2.1 Build a bounded SRQL preview/introspection context that applies preview limits and returns rows plus field metadata.
- [x] 2.2 Implement a visual registry that declares required field shapes and validates panel visual configs.
- [x] 2.3 Add backend validation so saved panels have valid SRQL, compatible visual config, and bounded refresh/report settings.
- [x] 2.4 Add tests for query preview success, invalid SRQL, unsupported visual mappings, and table fallback.
- [x] 2.5 Add `in:dashboards` SRQL entity support for searching authored dashboards and panel SRQL query text.

## 3. Dashboard Creator UI
- [x] 3.1 Add an Analytics dashboards workspace for listing saved dashboards and creating a new dashboard.
- [x] 3.2 Add a dashboard editor with SRQL query input, preview execution, field metadata display, visual picker, and panel config.
- [x] 3.3 Add layout editing for multiple panels with stable ordering and responsive rendering.
- [x] 3.4 Add saved dashboard show route at `/dashboard/:dashboard_id` without changing `/dashboard` or `/dashboards/:route_slug`.
- [x] 3.5 Add share/copy-link affordances and clear owner/visibility labels.
- [x] 3.6 Add dashboard-local settings for SRQL panels, visualization choices, schedules, and user/user-group access grants.
- [x] 3.7 Add `/dashboards` discovery hub with user favorites, per-user default selection, and system fallback to `/dashboards/service-availability-noc`.

## 4. Scheduled Reports
- [x] 4.1 Add a dashboard report schedule form with recipients, timezone, cadence/cron, enabled state, and next-run preview.
- [x] 4.2 Add one periodic scheduler job that finds due enabled schedules and enqueues per-due delivery jobs.
- [x] 4.3 Add an idempotent delivery worker that renders a bounded dashboard snapshot and sends email through existing mailer infrastructure.
- [x] 4.4 Persist delivery history with success/failure status, retry metadata, and operator-visible errors.
- [x] 4.5 Add tests covering due schedule scan, duplicate prevention, successful delivery, failure recording, and disabled schedules.
- [x] 4.6 Add deployment outbound mail settings with adapter selection and encrypted-local or credential-broker-backed secrets.
- [x] 4.7 Add an admin Settings UI for outbound mail configuration.
- [x] 4.8 Route dashboard report delivery through the shared outbound mail runtime.

## 5. Permissions and Navigation
- [x] 5.1 Add permissions for viewing, creating, editing, deleting, sharing, and scheduling authored dashboards.
- [x] 5.2 Add permissions for managing reusable user groups and viewing share principals.
- [x] 5.3 Decide and implement Analytics navigation placement without polluting the existing settings/sidebar structure.
- [x] 5.4 Ensure dashboard package management remains under Settings -> Dashboards and does not mix with authored dashboard CRUD.

## 6. Validation
- [x] 6.1 Run focused Ash/resource tests for dashboard resources and report jobs.
- [x] 6.2 Run focused LiveView tests for creator, editor, saved dashboard display, and report schedule workflows.
- [x] 6.3 Run `mix format` and relevant web-ng quality checks.
- [x] 6.4 Run `openspec validate add-dashboard-creator --strict`.
