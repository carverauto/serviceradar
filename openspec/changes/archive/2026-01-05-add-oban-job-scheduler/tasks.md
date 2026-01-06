## 1. Oban Integration
- [x] 1.1 Add Oban dependency to `web-ng/mix.exs`
- [x] 1.2 Configure Oban queues, plugins, and repo in `web-ng/config/runtime.exs`
- [x] 1.3 Add Oban to the web-ng supervision tree
- [x] 1.4 Generate and commit Oban migration for `oban_jobs`

## 2. Scheduler Coordination
- [x] 2.1 Configure Oban.Plugins.Cron with Oban.Peers.Database leader election
- [x] 2.2 Configure node identity + peers for multi-node deployments
- [x] 2.3 Add job uniqueness defaults for scheduled jobs (refresh worker)
- [x] 2.4 Add logging for leader selection and scheduling activity

## 3. Trace Summaries Refresh Job
- [x] 3.1 Implement `RefreshTraceSummariesWorker` (shared ServiceRadar job module) to run `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`
- [x] 3.2 Add Oban cron entry to run the worker every 2 minutes (from schedule config)
- [x] 3.3 Add guardrails/logging for missing MV or refresh failures

## 4. Job Scheduling Control Plane (Admin UI)
- [x] 4.1 Add job schedule storage (table + schema + context)
- [x] 4.2 Seed default schedule for trace summaries (2-minute cadence)
- [x] 4.3 Add admin UI pages for job list and schedule editing
- [x] 4.4 Add job run history + status in the admin UI (from `oban_jobs`)
- [ ] 4.5 Add manual "Run now" action for supported jobs
- [ ] 4.6 Remove Oban Web dependency + route once custom UI covers needs
- [x] 4.7 Defer RBAC: leave job UI unauthenticated for now (document)

## 5. Configuration and Ops
- [x] 5.1 Make refresh cadence configurable via environment variable (default seed)
- [x] 5.2 Ensure schedule changes apply without redeploy (cron refresh)
- [x] 5.3 Ensure dev/prod defaults align with current 2-minute cadence

## 6. Tests
- [x] 6.1 Add unit test for worker query construction and error handling
- [x] 6.2 Add integration test that enqueues the worker and verifies refresh invocation
- [x] 6.3 Add tests for schedule config loading and cron refresh
- [x] 6.4 Add tests for job history queries
- [ ] 6.5 Add tests for manual trigger actions

## 7. Documentation
- [x] 7.1 Update CNPG spec delta to reflect Oban-managed refresh + multi-node coordination
- [x] 7.2 Add job-scheduling spec with Oban requirements, admin UI, and coordination
