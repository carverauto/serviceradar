---
title: Observability Rollup Recovery
---

# Observability Rollup Recovery

Use this runbook when `/observability?tab=traces` or `/analytics` shows stale or obviously wrong trace-derived data, or when the UI warns that trace rollups need attention.

## Symptoms

- Trace counts or durations stay at zero even though `otel_traces` is ingesting data
- `/observability?tab=traces` loads but shows old trace rows only
- `/analytics` and trace summary cards stop changing
- The UI warns that `platform.otel_trace_summaries` or `platform.traces_stats_5m` is missing or stale

## Quick Verification

Connect to the primary CNPG instance:

```bash
kubectl exec -it <cnpg-primary-pod> -n <namespace> -- psql -U serviceradar -d serviceradar
```

Check that the maintained trace assets exist:

```sql
SELECT to_regclass('platform.otel_trace_summaries') AS trace_summary_table;

SELECT view_schema, view_name
FROM timescaledb_information.continuous_aggregates
WHERE view_schema = 'platform'
  AND view_name = 'traces_stats_5m';
```

Compare raw ingest with maintained outputs:

```sql
SELECT
  (SELECT max(timestamp) FROM platform.otel_traces) AS raw_latest,
  (SELECT max(timestamp) FROM platform.otel_trace_summaries) AS summary_latest,
  (SELECT max(bucket) FROM platform.traces_stats_5m) AS rollup_latest;
```

If `raw_latest` is materially newer than `summary_latest` or `rollup_latest`, trace maintenance is stale.

## Check the Scheduler

See the [OTel storage model](./otel.md#storage-model) for trace summary refresh
triggers and scheduling. A separate reaper clears stale periodic jobs. Inspect
their recent runs:

```sql
SELECT worker, state, queue, attempt, attempted_at, completed_at, scheduled_at
FROM platform.oban_jobs
WHERE worker LIKE 'ServiceRadar.Jobs.%'
ORDER BY inserted_at DESC
LIMIT 20;
```

In a healthy steady state, the trace refresh and reaper workers show recent
`completed` rows and no long-lived `executing` rows.

## Remediation

The stale-job reaper and trace summary refresh both run automatically. If
recovery is lagging, an operator can trigger them immediately from a release
shell in the core runtime:

```bash
kubectl exec -it deploy/serviceradar-core-elx -n <namespace> -- /app/bin/serviceradar_core_elx remote
```

### 1. Reap stale periodic jobs

```elixir
alias ServiceRadar.Jobs.ReapStalePeriodicJobsWorker
{:ok, _job} = Oban.insert(ReapStalePeriodicJobsWorker.new(%{}, queue: :maintenance))
```

### 2. Trigger trace summary refresh

After stale jobs are cleared, enqueue a refresh from the same shell:

```elixir
alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
{:ok, _job} = Oban.insert(RefreshTraceSummariesWorker.new(%{}, queue: :maintenance))
```

### 3. Verify progress

Re-run the freshness query:

```sql
SELECT
  (SELECT max(timestamp) FROM platform.otel_traces) AS raw_latest,
  (SELECT max(timestamp) FROM platform.otel_trace_summaries) AS summary_latest,
  (SELECT max(bucket) FROM platform.traces_stats_5m) AS rollup_latest;
```

Also confirm recent completed jobs:

```sql
SELECT worker, state, completed_at
FROM platform.oban_jobs
WHERE worker = 'ServiceRadar.Jobs.RefreshTraceSummariesWorker'
ORDER BY inserted_at DESC
LIMIT 5;
```

## When Recovery Fails

If the summary worker keeps retrying or timing out:

- check `serviceradar-core-elx` logs for DB checkout or statement timeouts
- verify `platform.otel_trace_summaries` is being pruned and is not growing without bound

If `platform.otel_trace_summaries` or `platform.traces_stats_5m` is missing
entirely after an upgrade, rerun migrations before attempting manual recovery.
