# Tasks

## 1. Agent: route AWX verbs to the awx plugin
- [x] 1.1 Add a control_stream route so `awx.*` command types invoke the awx
      plugin `run_check` entrypoint with the verb + payload.
- [x] 1.2 Return the plugin's result (job id / events / error) as the command
      result so `AnsibleEventIngestor` can advance the run state machine.
- [x] 1.3 Verify the durable v1.4.13 agent/core deployment includes the AWX verb route; the in-cluster `k8s-agent` is running the release artifact, replacing the earlier ad hoc binary rollout.

## 2. Catalog + launch (core, mostly landed)
- [x] 2.1 Confirm `AwxCatalogSyncWorker` produces four `Playbook` rows from AWX
      job templates once verbs route.
- [x] 2.2 Retain the landed `run_launcher` metadata.awx correlation and `awx_client` capability fix from PR #4434; known hostname/inventory hardening gaps remain owned by `add-ansible-integration` and its follow-up.

## 3. Verify the operator flow
- [x] 3.1 Create a trivial AWX job template (e.g. ping) and ensure the target
      device (agent 192.168.2.22 or a synced host) is in the AWX inventory.
- [x] 3.2 Verify the deployed operator flow has six succeeded runs and persisted run hierarchy data (13 targets, 7 plays, 12 tasks, and 11 task results); failed/unreachable runs remain visible rather than disappearing.
- [x] 3.3 Verify the route/tests landed through PR #4434 and the durable v1.4.13 agent/core deployment.
