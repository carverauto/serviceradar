---
sidebar_position: 80
---

# Object Store Retention

ServiceRadar stores durable internal artifacts in NATS JetStream Object Store. The current ServiceRadar-owned namespaces are:

- `agent-releases/<version>/...` for mirrored agent release artifacts stored through datasvc
- `plugins/<plugin_id>/<version>/<package_id>.wasm` for uploaded Wasm plugin packages when plugin storage uses the JetStream backend

Retention is disabled by default and runs in dry-run mode when enabled unless configured otherwise.

## Helm Configuration

```yaml
objectStoreRetention:
  enabled: true
  dryRun: true
  cron: "0 3 * * *"
  agentReleaseKeepLatest: 5
  pluginOrphanGraceSeconds: 604800
  datasvcTimeoutMs: 30000
```

`cron` controls the Oban cron schedule for cleanup. The default is once daily at 03:00.

`agentReleaseKeepLatest` controls how many published agent releases are always retained. The retention planner also protects release artifacts referenced by active or paused rollouts and non-terminal rollout targets.

`pluginOrphanGraceSeconds` controls how old inactive plugin blobs must be before they are eligible for deletion. Staged and approved packages are protected, as are packages referenced by assignments or target policies.

## Running Cleanup

Agent release artifact cleanup is handled by `ServiceRadar.ObjectStore.RetentionWorker` in the `maintenance` Oban queue. Plugin blob cleanup is handled by `ServiceRadarWebNG.Plugins.BlobRetentionWorker` and requires web-ng to process the `maintenance` queue.

Manual dry-run enqueue from an attached IEx shell:

```elixir
ServiceRadar.ObjectStore.RetentionWorker.enqueue_manual(dry_run?: true)
ServiceRadarWebNG.Plugins.BlobRetentionWorker.enqueue_manual(dry_run?: true)
```

For an initial production pass, keep `dryRun: true` and inspect the summary logs:

```text
ObjectStoreRetention: release artifact cleanup completed scanned=... protected=... eligible=... deleted=0 dry_run=true
PluginBlobRetention: cleanup completed scanned=... protected=... eligible=... deleted=0 dry_run=true
```

Set `dryRun: false` only after the eligible counts look correct.
