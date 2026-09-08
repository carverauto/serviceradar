## Context

The zen service (Rust-based rule engine) requires decision graph rules to be stored in NATS JetStream KV bucket. In docker compose, these rules are installed on first startup via an entrypoint script. In Kubernetes, this initialization step is missing, causing zen to fail when attempting to load rules from the KV store.

The error `missing field 'nodes'` indicates that either:
1. The rule data is corrupted/malformed in the KV store
2. The rule was never installed (404) and zen has fallback handling issues
3. A previous version stored rules in a different format

## Goals / Non-Goals

**Goals:**
- Ensure zen rules are properly bootstrapped in Kubernetes deployments
- Maintain parity with docker compose behavior
- Support clean installs and upgrades
- Allow operators to force-reinstall rules if needed

**Non-Goals:**
- Changing the rule format or storage mechanism
- Adding a UI for rule management (covered by separate spec)
- Cleaning up existing corrupted rules (this is a bootstrap solution)

## Decisions

### Decision: Use a Kubernetes Job with Helm Hooks

**What:** Create a Kubernetes Job that runs as a post-install/post-upgrade Helm hook to bootstrap zen rules.

**Why:**
- Jobs are appropriate for one-time initialization tasks
- Helm hooks ensure the job runs at the right time (after NATS is ready, before zen starts)
- Jobs can be retried on failure
- Separates bootstrap concerns from the main zen deployment

**Alternatives considered:**
1. **Init container on zen deployment**: Would delay zen startup and doesn't handle upgrade scenarios well
2. **Sidecar container**: Overkill for a one-time task, wastes resources
3. **Use existing entrypoint script**: Would require changing the bazel-built image to include the docker compose scripts

### Decision: Reuse existing zen-put-rule binary

**What:** Use the `zen-put-rule` binary already built as part of the zen package to install rules.

**Why:**
- Already proven to work in docker compose
- Handles NATS/TLS connection properly
- Validates rule format before insertion
- No new code needed for the core installation logic

### Decision: Mount rules from ConfigMap

**What:** The bootstrap job mounts `serviceradar-zen-rules` ConfigMap which already contains the rule JSON files.

**Why:**
- ConfigMap already exists and is maintained
- Rules are versioned with the Helm chart
- No duplication of rule definitions

## Rule-to-Subject Mapping

The following rules need to be installed with their corresponding NATS subjects:

| Rule File | NATS Subject | Rule Key |
|-----------|--------------|----------|
| strip_full_message.json | logs.syslog | strip_full_message |
| cef_severity.json | logs.syslog | cef_severity |
| snmp_severity.json | logs.snmp | snmp_severity |
| passthrough.json | logs.otel | passthrough |

## Risks / Trade-offs

**Risk:** Job may fail if NATS or datasvc is not ready
**Mitigation:** Add init container that waits for dependencies, use job retry policy

**Risk:** Rules could be overwritten on upgrade, losing custom modifications
**Mitigation:** Only install if rule doesn't exist (unless forceReinstall is enabled)

**Trade-off:** Using a Job means the bootstrap is a separate pod from zen
**Accepted:** This follows k8s patterns and keeps concerns separated

## Migration Plan

1. Deploy the new Helm chart version with the bootstrap job
2. Job runs automatically after install/upgrade
3. Zen pods restart and should now find valid rules in KV
4. No manual intervention required

For existing environments with corrupted rules:
- Option A: Set `zenRulesBootstrap.forceReinstall: true` for one upgrade
- Option B: Manually delete corrupted KV entries before upgrade

## Open Questions

- Should we add a cleanup mechanism to remove old/corrupted rules?
- Should the job have a TTL for automatic cleanup after success?
