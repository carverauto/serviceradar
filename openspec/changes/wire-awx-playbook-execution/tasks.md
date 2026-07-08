# Tasks

## 1. Agent: route AWX verbs to the awx plugin
- [ ] 1.1 Add a control_stream route so `awx.*` command types invoke the awx
      plugin `run_check` entrypoint with the verb + payload.
- [ ] 1.2 Return the plugin's result (job id / events / error) as the command
      result so `AnsibleEventIngestor` can advance the run state machine.
- [ ] 1.3 Build the agent locally; push the binary to the in-cluster `k8s-agent`
      (kubectl cp + restart) and to PVE agents as needed.

## 2. Catalog + launch (core, mostly landed)
- [ ] 2.1 Confirm `AwxCatalogSyncWorker` now produces `Playbook` rows from AWX
      job templates once verbs route.
- [ ] 2.2 Keep `run_launcher` metadata.awx correlation + `awx_client` capability
      fix (branch `fix/awx-inventory-sync-and-playbook-run`).

## 3. Verify the operator flow
- [ ] 3.1 Create a trivial AWX job template (e.g. ping) and ensure the target
      device (agent 192.168.2.22 or a synced host) is in the AWX inventory.
- [ ] 3.2 From the device detail page (or `RunLauncher.launch`), launch the
      playbook; confirm the run reaches `succeeded` with populated plays/tasks.
- [ ] 3.3 Add tests; land via PR; durable agent+core deploy.
