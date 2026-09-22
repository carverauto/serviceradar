## 0. Configure complementary Kubernetes readiness alerting

`add-k8s-node-readiness-alerts` owns readiness condition rules and notification
setup. Reuse that change's provisioning flow; generic alert-rule JSON:API
work remains separately scoped as `add-alert-rule-json-api`. These are
operator setup tasks, not observations about any existing deployment.

- [ ] 0.1 Select the Kubernetes nodes to monitor and an enabled notification
      channel, then use `serviceradar-cli notifications ensure-k8s-alerts`
      according to that change's configuration contract.
- [ ] 0.2 Verify readiness failure and recovery notifications with synthetic
      inputs in a disposable test environment.

## 1. Configure baseline availability monitoring

These checks complement readiness alerting and can be configured independently
of the plugin work in sections 2-5.

- [ ] 1.1 Select an executor that supports raw ping/TCP ServiceChecks and can
      reach the targets, preferably outside their failure domain.
- [ ] 1.2 Use `POST /api/v2/service-checks` for the operator-selected
      Kubernetes API endpoints.
- [ ] 1.3 Use `POST /api/v2/service-checks` for the selected Proxmox hosts.
- [ ] 1.4 Force a failure against a disposable target and confirm that an
      Alert is generated and delivered through the selected notification
      route; confirm recovery afterward.

## 2. Land prerequisites (tracked in their own changes)

- [ ] 2.1 Land `fix-proxmox-inventory-plugin-reliability` so guest
      running/stopped status is trustworthy.
- [ ] 2.2 Complete `add-plugin-alert-rules`.

## 3. Proxmox plugin: guest availability event

- [ ] 3.1 In `go/cmd/wasm-plugins/proxmox/`, emit a
      `com.carverauto.proxmox.guest_availability_changed` condition event on
      a running-to-stopped transition, carrying the guest's canonical
      DeviceID and Proxmox node.
- [ ] 3.2 Unit test with invented guest observations: running in poll N and
      stopped in N+1 emits exactly one event; remaining stopped emits none.
- [ ] 3.3 Confirm the event remains separate from the periodic
      ok/warning/critical pressure summaries.

## 4. Proxmox plugin: host OOM-kill detection

- [ ] 4.1 Determine the supported node kernel-log source and permissions
      within the plugin execution and unified credential contracts.
- [ ] 4.2 Poll each node's log since the last successful poll for OOM-killer
      entries, such as `oom-kill:` or "Out of memory: Killed process".
- [ ] 4.3 Emit a `com.carverauto.proxmox.node_oom_kill` condition event per
      match, carrying node name, killed process name/pid when parseable,
      and the raw log line as event detail.
- [ ] 4.4 Unit test using log fixtures invented from scratch: a new OOM-kill
      entry emits an event with expected fields; no matching entry emits
      none; an entry processed in a previous poll is not emitted again.

## 5. Manifest wiring

- [ ] 5.1 Add `alert_rules:` entries to
      `go/cmd/wasm-plugins/proxmox/plugin.yaml` for
      `guest-availability-changed` and `node-oom-kill`, matching the schema
      defined by `add-plugin-alert-rules`; do not set `enabled` or `priority`.
- [ ] 5.2 Ship a new plugin package version and verify approval materializes
      both rules disabled and namespaced `plugin:proxmox:<name>`.

## 6. Verification

- [ ] 6.1 Enable both rules through the existing alert-rules UI in a
      disposable test environment.
- [ ] 6.2 Stop a disposable guest and separately simulate a host OOM kill;
      confirm each alert reaches the selected notification route within the
      configured rule window. Do not commit captured logs or test-environment
      identifiers; repository fixtures must be invented from scratch.
- [ ] 6.3 Run `openspec validate add-proxmox-host-outage-alerting --strict`.
