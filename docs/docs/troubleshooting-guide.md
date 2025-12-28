---
title: Troubleshooting Guide
---

# Troubleshooting Guide

Use this guide as a first stop when onboarding ServiceRadar or operating the demo cluster. Each section lists fast diagnostics, common failure modes, and references for deeper dives.

## Edge Agents

Edge agents are Go binaries that run on monitored hosts outside the Kubernetes cluster, communicating via gRPC with mTLS.

### Connection Issues

- **Agent not connecting**: Check agent logs (`journalctl -u serviceradar-agent -f`) for connection errors. Verify the poller address in `/etc/serviceradar/agent.json`.
- **TLS handshake failures**: Ensure certificates are valid and the CA bundle is correct:
  ```bash
  openssl verify -CAfile /etc/serviceradar/certs/bundle.pem \
    /etc/serviceradar/certs/svid.pem
  ```
- **Firewall blocking**: Confirm port 50051 is open from the agent to the poller:
  ```bash
  nc -zv <poller-host> 50051
  ```

### Certificate Issues

- **Certificate expired**: Check expiry dates:
  ```bash
  openssl x509 -in /etc/serviceradar/certs/svid.pem -noout -dates
  ```
- **Wrong CN format**: Verify the CN matches `<agent_id>.<partition_id>.<tenant_slug>.serviceradar`:
  ```bash
  openssl x509 -in /etc/serviceradar/certs/svid.pem -noout -subject
  ```
- **CA mismatch**: Ensure the agent's CA bundle matches the cluster's SPIRE trust domain.

### Registration Issues

- **Agent not appearing in UI**: Verify the agent is registered via the API:
  ```bash
  curl -H "Authorization: Bearer $TOKEN" \
    https://core.example.com/api/v2/agents/<agent-uid>
  ```
- **Status stuck at "connecting"**: Check poller logs for gRPC errors. The agent may be connecting but failing health checks.
- **Wrong tenant**: Agent certificates are tenant-specific. Verify the tenant slug in the certificate CN matches the expected tenant.

### gRPC Diagnostics

Test gRPC connectivity directly:
```bash
grpcurl -cert /etc/serviceradar/certs/svid.pem \
        -key /etc/serviceradar/certs/svid-key.pem \
        -cacert /etc/serviceradar/certs/bundle.pem \
        <poller-host>:50053 list
```

For detailed edge agent documentation, see [Edge Agents](./edge-agents.md).

## Core Services

- **Check pod health**: `kubectl get pods -n demo` (or the equivalent Docker Compose status). Pods stuck in `CrashLoopBackOff` usually point to missing secrets or PVC mounts.
- **Verify API availability**: `curl -k https://<core-host>/healthz`. TLS errors tie back to mismatched certificates—reissue them with the [Self-Signed Certificates guide](./self-signed.md).
- **Configuration drift**: Reconcile changes with the [Configuration Basics](./configuration.md) checklist and commit updates to KV.

## SNMP

- **Credential failures**: Review `poller` logs for `snmp_auth_error`. Ensure v3 auth/privacy keys match the [SNMP ingest guide](./snmp.md) recommendations.
- **Packet loss**: Confirm firewall rules allow UDP 161/162 from pollers. Use `snmpwalk -v3 ...` from the poller pod to validate.
- **Slow polls**: Trim OID lists or increase poller replicas. Long runtimes delay alerting.

## Syslog

- **No events**: Ensure devices forward to the correct address and protocol (`UDP/TCP 514`). Validate listener status via `kubectl logs deploy/serviceradar-syslog -n demo`.
- **Parsing issues**: Update CNPG grok rules when new vendors join; refer to the [Syslog ingest guide](./syslog.md).
- **Clock drift**: Systems with unsynchronized NTP create out-of-order events; align to UTC.

## NetFlow

- **Missing flows**: Exporters must send to UDP 2055. Use `tcpdump` on the poller host to confirm arrival.
- **Template errors**: Reset exporters or clear caches when poller logs complain about unknown IPFIX templates. See the [NetFlow ingest guide](./netflow.md).
- **High load**: Increase `NETFLOW_QUEUE_DEPTH` and allocate more CPU to pollers.

## OTEL

- **TLS failures**: Double-check the OTLP gateway certificate bundle. Clients should trust the CA described in [Self-Signed Certificates](./self-signed.md).
- **Backpressure**: Inspect the gateway metrics; enable batching in exporters. Follow the [OTEL guide](./otel.md) for tuning tips.
- **Missing spans**: Ensure `service.name` and other attributes are populated—SRQL filters rely on them.

## Discovery

- **Empty results**: Confirm scopes exist in KV under `discovery/jobs/*`. Reconcile job ownership using the [Discovery guide](./discovery.md).
- **Mapper stalled**: Tail `serviceradar-mapper` logs for `scheduler` messages. Ensure `/etc/serviceradar/mapper.json` has at least one enabled `scheduled_jobs` entry and that credentials cover the target CIDRs.
- **Missing interfaces/topology**: Verify `stream_config` in `mapper.json` still points to `discovered_interfaces` and `topology_discovery_events`. Mapper only emits interface/topology data when those fields are present.
- **Duplicate devices**: Enable canonical matching in Sync so NetBox and Armis merges succeed.
- **Sweep failures**: Check poller network reachability and throttling limits.

## Integrations

### Armis

- Refresh client secrets and inspect `serviceradar-sync` logs. The [Armis integration doc](./armis.md) covers faker resets and pagination tuning.
- Compare Faker vs. production counts to spot ingestion gaps.

### NetBox

- Verify API token scopes and rate limits. See the [NetBox integration guide](./netbox.md) for advanced settings.
- Check that prefixes are importing as expected; toggle `expand_subnets` if sweep jobs look incomplete.

## Dashboards and UI

- **Login problems**: Ensure local users exist (`admin` role) and JWT secrets are configured as described in [Authentication configuration](./auth-configuration.md).
- **Missing charts**: Import default dashboards from the [Web UI configuration](./web-ui.md) and double-check CNPG retention windows.
- **SRQL errors**: Reference the [SRQL language guide](./srql-language-reference.md) when writing complex joins.

## Still Stuck?

- Review the operational runbooks in [Agents & Demo Operations](./agents.md) for environment resets.
- Capture failing commands, logs, and SRQL queries before escalating to the core team.
- File follow-up work items in Beads (`bd`) so the broader team can track remediations.
