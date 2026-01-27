# Change: Fix Zen Rule Bootstrap in Kubernetes

## Why

The zen service fails to load rules in Kubernetes environments with the error:
```
failed to load rule events/logs.syslog/strip_full_message: missing field `nodes` at line 27 column 1
```

This happens because:
1. Docker Compose uses a custom entrypoint (`entrypoint-zen.sh`) that runs `zen-install-rules.sh` on first startup to insert rules into NATS KV using the `zen-put-rule` binary
2. Kubernetes/Helm deployment does NOT have this initialization mechanism - rules are only mounted as a ConfigMap but never installed to the NATS KV bucket
3. The k8s NATS KV bucket has stale/malformed rule data that doesn't match the expected `DecisionContent` structure (missing `nodes` field)

GitHub Issue: #2426

## What Changes

- Add a Kubernetes Job that runs on Helm install/upgrade to bootstrap zen rules into NATS KV
- Use the existing `zen-put-rule` binary to install rules from the ConfigMap
- Implement idempotency by checking if rules already exist with valid format before re-installing
- Add helm values to control rule bootstrap behavior (enable/disable, force reinstall)

## Impact

- Affected specs: `observability-rule-management`
- Affected code:
  - `helm/serviceradar/templates/zen-rules-bootstrap-job.yaml` (new)
  - `helm/serviceradar/values.yaml` (add zen bootstrap config)
  - `cmd/consumers/zen/Dockerfile` (ensure zen-put-rule is included)
