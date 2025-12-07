# Change: Fix ICMP Collector Attribution for Service Devices

## Why
ICMP sparklines disappeared for `k8s-agent` in the demo Kubernetes inventory (issue #2069). Agent ICMP responses now carry a `device_id` derived from `host_ip`, and in Helm/docker defaults that value is the placeholder `"agent"`. Core trusts that `device_id` even when an `agent_id` is present, so ICMP capability snapshots and metrics end up on a non-existent `default:agent` device instead of `serviceradar:agent:k8s-agent`, leaving the UI with no ICMP hint or metrics for the agent.

## What Changes
- Keep agent-originated ICMP capability snapshots and metrics attached to the agent service device, even when payloads include a target `device_id` or placeholder host identifiers; capture the target in metadata instead of promoting it to the primary device ID.
- Normalize or discard non-IP host/device hints from ICMP payloads so registry capability snapshots and metric summaries consistently show ICMP availability for collector devices in both k8s and docker stacks.
- Add regression coverage for agent ICMP payloads that include `device_id` to ensure collector capability snapshots, metric summaries, and device responses surface ICMP for `k8s-agent`.

## Impact
- Affected specs: `service-device-capabilities`
- Affected code: agent ICMP checker device_id construction, core ICMP device resolution/capability snapshotting, registry metric summaries and collector capability hints (UI sparklines consume these)
