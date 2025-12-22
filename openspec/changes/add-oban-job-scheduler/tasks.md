## 1. Oban Integration
- [ ] 1.1 Add Oban dependency to `web-ng/mix.exs`
- [ ] 1.2 Configure Oban queues and plugins in `web-ng/config/runtime.exs`
- [ ] 1.3 Add Oban to the web-ng supervision tree
- [ ] 1.4 Generate and commit Oban migration for `oban_jobs`

## 2. Trace Summaries Refresh Job
- [ ] 2.1 Implement `RefreshTraceSummariesWorker` to run `REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries`
- [ ] 2.2 Add Oban cron entry to run the worker every 2 minutes
- [ ] 2.3 Add guardrails/logging for missing MV or refresh failures

## 3. Configuration and Ops
- [ ] 3.1 Make refresh cadence configurable via environment variable
- [ ] 3.2 Ensure dev/prod defaults align with current 2-minute cadence

## 4. Tests
- [ ] 4.1 Add unit test for worker query construction and error handling
- [ ] 4.2 Add integration test that enqueues the worker and verifies refresh invocation

## 5. Documentation
- [ ] 5.1 Update CNPG spec delta to reflect Oban-managed refresh
- [ ] 5.2 Add job-scheduling spec with Oban requirements
