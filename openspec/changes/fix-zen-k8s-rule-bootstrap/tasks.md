## 1. Investigation & Design

- [x] 1.1 Investigate root cause by comparing docker compose vs k8s zen startup
- [x] 1.2 Verify the rule format expected by zen-engine (`DecisionContent` with `nodes` and `edges`)
- [x] 1.3 Confirm docker compose uses `zen-put-rule` via entrypoint script

## 2. Helm Template Changes

- [x] 2.1 Create `zen-rules-bootstrap-job.yaml` that runs as a Helm hook (post-install, post-upgrade)
- [x] 2.2 Job should use the zen image with access to `zen-put-rule` binary
- [x] 2.3 Mount the `serviceradar-zen-rules` ConfigMap containing rule JSON files
- [x] 2.4 Mount required certs and NATS credentials for connecting to datasvc

## 3. Rule Installation Logic

- [x] 3.1 Create bootstrap script that iterates over mounted rule files
- [x] 3.2 For each rule, call `zen-put-rule --file <path> --subject <subject> --key <name>`
- [x] 3.3 Handle rule-to-subject mapping (strip_full_message/cef_severity -> logs.syslog, etc.)
- [x] 3.4 Add error handling and logging for rule installation failures

## 4. Idempotency & Configuration

- [x] 4.1 Add helm values for zen rule bootstrap configuration:
  - `zenRulesBootstrap.enabled` (default: true)
  - `zenRulesBootstrap.forceReinstall` (default: false)
- [ ] 4.2 If forceReinstall is false, check if rule exists before installing
- [x] 4.3 Add annotation to job for Helm hook delete policy

## 5. Docker Image Updates

- [x] 5.1 Verify `zen-put-rule` binary is included in the bazel-built zen image
- [x] 5.2 If not, update BUILD.bazel to include the binary in the image (already included)

## 6. Testing

- [ ] 6.1 Test fresh install in a k8s environment
- [ ] 6.2 Verify rules are properly installed and zen can load them
- [ ] 6.3 Test upgrade scenario - rules should not be overwritten if already valid
- [ ] 6.4 Test forceReinstall option
