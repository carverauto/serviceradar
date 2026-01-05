---
title: NetBox Integration
---

# NetBox Integration

The NetBox connector keeps ServiceRadar's registry synchronized with your source-of-truth CMDB. It imports devices, IP addresses, and services, then seeds discovery sweeps and monitoring profiles.

## Requirements

- NetBox 3.5+ with API access enabled.
- A service account token scoped to read device, IPAM, and virtualization objects.
- Outbound HTTPS connectivity from the ServiceRadar agent (embedded sync runtime) to your NetBox deployment.

## Configuration Steps

1. Create a NetBox integration source in **Integrations → New Source** (Armis/NetBox). Provide the endpoint, token, prefix, and partition.
2. Ensure a sync-capable agent is connected. Tail `kubectl logs deploy/serviceradar-agent -n demo` and look for `netbox_sync` entries confirming pulls.

## How Data Flows

- Devices and VMs become registry entries tagged with `source=netbox`.
- Prefixes and IP addresses translate into sweep jobs, which pollers pick up automatically (see [Discovery Guide](./discovery.md)).
- Site, tenant, and device-role metadata convert into labels that surface in SRQL and dashboards.

## Advanced Options

| Option | Description | Default |
|--------|-------------|---------|
| `expand_subnets` | Expand prefixes into host entries rather than treating them as /32 hosts. | `false` |
| `insecure_skip_verify` | Skip TLS validation when using self-signed certs. Combine with the [Self-Signed Certificates guide](./self-signed.md). | `false` |
| `partition` | Override the destination registry partition. | `default` |

## Validation

- Run `in:devices source:netbox sort:hostname limit:20` in SRQL to confirm imports.
- Compare interface counts against NetBox inventory; mismatches usually stem from stale caching.
- Use the [Service Port Map](./service-port-map.md) to confirm Layer 2/3 relationships were derived correctly.

## Troubleshooting

- Permission errors indicate insufficient API scopes—Double-check the service account roles.
- Large imports can breach NetBox rate limits. Set `page_size` in the integration config or enable result caching in the embedded sync runtime.
- See the [Troubleshooting Guide](./troubleshooting-guide.md#netbox) for remediation tips and log locations.
