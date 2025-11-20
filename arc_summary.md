# ARC Runner Troubleshooting Summary (Nov 20)

## What went wrong
- Scale set hit ImagePullBackOff initially (private image), then oscillated runners because stale EphemeralRunnerSets couldn’t be patched and runner pods exited instantly.
- Runner pods were configured with custom commands that ended immediately; they registered as offline and jobs queued.
- openssl-sys build scripts failed on RBE due to pointing at /usr/lib/x86_64-linux-gnu (not present in the executor image) with OPENSSL_NO_VENDOR set.

## Fixes applied
- Built and pushed custom runner image `ghcr.io/carverauto/serviceradar/arc-runner:latest` with cmake/flex/bison/perl/protoc/libssl-dev.
- Helm upgrade for arc-runner-set to use that image and ghcr pull secret; reset autoscaling min=0 max=20.
- Cleaned ARC state: deleted stale EphemeralRunnerSets, restarted controller/listener, and set runner command back to `run.sh --jitconfig "$ACTIONS_RUNNER_INPUT_JITCONFIG" --once` with label `self-hosted,Linux,X64,arc-runner-set`.
- Latest loop (listener starting then dying) was caused by the listener pointing at a non-existent EphemeralRunnerSet (`arc-runner-set-5rh92`). Patched the listener to the live set (`arc-runner-set-ltj85`) after deleting stale EphemeralRunnerSets and the listener.
- `.bazelrc`: set OPENSSL_DIR=/usr, OPENSSL_LIB_DIR=/usr/lib64, OPENSSL_INCLUDE_DIR=/usr/include for remote builds/tests so openssl-sys finds OpenSSL on RBE.

## Current status
- Listener running; EphemeralRunnerSet `arc-runner-set-ltj85` is current, and runners should stay up and process jobs.
- CICD jobs are progressing; openssl-sys should no longer fail on missing libssl paths.

## Commands to recover if ARC thrashes again
1) Patch autoscaling runner spec back to clean defaults:
   ```bash
   kubectl patch autoscalingrunnerset arc-runner-set -n arc-systems --type merge -p '{"spec":{"minRunners":0,"maxRunners":20,"template":{"spec":{"containers":[{"name":"runner","image":"ghcr.io/carverauto/serviceradar/arc-runner:latest","command":["/home/runner/run.sh"],"args":["--jitconfig","$(ACTIONS_RUNNER_INPUT_JITCONFIG)","--once"],"env":[{"name":"ACTIONS_RUNNER_LABELS","value":"self-hosted,Linux,X64,arc-runner-set"}]}],"imagePullSecrets":[{"name":"ghcr-pull"}]}}}}'
   ```
2) Delete all EphemeralRunnerSets and listener to clear stale state:
   ```bash
   kubectl delete ephemeralrunnersets -n arc-systems --all
   kubectl delete pod -n arc-systems -l app.kubernetes.io/component=listener
   ```
   Wait for controller to recreate listener and a fresh EphemeralRunnerSet.
3) Verify pods and runners:
   ```bash
   kubectl get pods -n arc-systems
   gh api /repos/carverauto/serviceradar/actions/runners --jq '.runners[] | {name:.name,status:.status,labels:[.labels[].name]}'
   ```

## Notes
- Custom command overrides that end quickly will cause runners to exit and appear offline; keep the default run.sh invocation.
- ARC patch errors often mean an EphemeralRunnerSet was deleted; clearing and letting the controller recreate it is the fastest fix.
- RBE executor has OpenSSL in /usr/lib64; prefer that path in build envs.
