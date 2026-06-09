---
sidebar_position: 80
---

# Object Store Retention

ServiceRadar stores durable internal artifacts in NATS JetStream Object Store. The current ServiceRadar-owned namespaces are:

- `agent-releases/<version>/...` for mirrored agent release artifacts stored through datasvc
- `plugins/<plugin_id>/<version>/<package_id>.wasm` for uploaded Wasm plugin packages when plugin storage uses the JetStream backend

Retention is enabled by default. Agent release cleanup keeps one locally imported
release by default, plus any release referenced by active or paused rollouts and
non-terminal rollout targets.

## Helm Configuration

```yaml
objectStoreRetention:
  enabled: true
  dryRun: false
  cron: "0 3 * * *"
  agentReleaseKeepLatest: 1
  pluginOrphanGraceSeconds: 604800
  datasvcTimeoutMs: 30000
```

`cron` controls the Oban cron schedule for cleanup. The default is once daily at 03:00.

`agentReleaseKeepLatest` controls how many locally imported agent releases are always retained. The default is `1`, so importing an older release effectively replaces the previous unreferenced import in datasvc object storage. The retention planner also protects release artifacts referenced by active or paused rollouts and non-terminal rollout targets.

`pluginOrphanGraceSeconds` controls how old inactive plugin blobs must be before they are eligible for deletion. Staged and approved packages are protected, as are packages referenced by assignments or target policies.

The release-management UI is intentionally bounded to the latest five published releases and the latest five discovered repository releases. The retention planner is the source of truth for artifact cleanup; the UI limit prevents old object-store history from looking like recommended rollout choices.

The plugin admin UI paginates installed plugin packages ten rows at a time. Object-store retention still protects staged, approved, assigned, and policy-referenced plugin blobs; operators should treat older unreferenced blobs as cleanup candidates rather than active package recommendations.

## Running Cleanup

Agent release artifact cleanup is handled by `ServiceRadar.ObjectStore.RetentionWorker` in the `maintenance` Oban queue. Plugin blob cleanup is handled by `ServiceRadarWebNG.Plugins.BlobRetentionWorker` and requires web-ng to process the `maintenance` queue.

Manual dry-run enqueue from an attached IEx shell:

```elixir
ServiceRadar.ObjectStore.RetentionWorker.enqueue_manual(dry_run?: true)
ServiceRadarWebNG.Plugins.BlobRetentionWorker.enqueue_manual(dry_run?: true)
```

To preview cleanup before deleting anything, temporarily set `dryRun: true` and inspect the summary logs:

```text
ObjectStoreRetention: release artifact cleanup completed scanned=... protected=... eligible=... deleted=0 dry_run=true
PluginBlobRetention: cleanup completed scanned=... protected=... eligible=... deleted=0 dry_run=true
```

Set `dryRun: false` again after the eligible counts look correct.
