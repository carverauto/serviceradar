---
sidebar_position: 8
title: KV Store Configuration
---

# KV Store Configuration

ServiceRadar uses NATS JetStream for platform KV and object storage. Most deployments use the defaults from Docker Compose or Helm and do not need manual KV setup.

## Summary

- **Datasvc** exposes KV and object APIs over gRPC.
- **NATS JetStream** stores the data.
- **mTLS** is required for all KV access.
- **Service configuration is no longer stored in KV**; services load config from files or gRPC.

## When to Configure Manually

Only needed if you are running Datasvc and NATS outside the standard Compose/Helm stack.

## Required Settings (datasvc.json)

- `listen_addr`: gRPC bind address for Datasvc (default 50057).
- `nats_url`: NATS endpoint (default `nats://localhost:4222`).
- `security.mode`: `mtls`.
- `security.cert_dir`: `/etc/serviceradar/certs`.
- `bucket`: KV bucket name (default `serviceradar-datasvc`).

## Operational Check

If the UI shows missing config metadata, confirm core can reach datasvc/NATS and that the service templates are registered:

```bash
curl -sS -H "Authorization: Bearer ${TOKEN}" \\
  https://<core-host>/api/admin/config | jq '.[].service_type'
```

For TLS setup, see [TLS Security](./tls-security.md).
