---
sidebar_position: 10
title: Kubernetes Ingress Services
---

# Kubernetes Ingress Services

Use this page when planning the public-cloud ingress resources needed for a ServiceRadar Kubernetes deployment. The list separates required control-plane ingress from optional telemetry collectors.

Do not expose internal service ports directly. Public traffic should terminate at a Gateway, ingress controller, or explicitly scoped collector `LoadBalancer`/`NodePort` equivalent, with firewall and source-CIDR controls wherever the sender set is known.

## Baseline Ingress

| Purpose | Public Port | Protocol | Kubernetes Backend | Cloud Resource Shape | Notes |
|---|---:|---|---|---|---|
| Web UI, API, LiveView, and browser streams | 443, optional 80 redirect | HTTPS | `serviceradar-web-ng:4000` | Shared or dedicated Gateway listener, DNS record, TLS certificate | Route `/`, `/api`, `/api/query`, websocket paths, and stream paths to web-ng. |
| Edge agent gateway | 50052 | mTLS gRPC | `serviceradar-agent-gateway` | Gateway TCP listener or deployment-reachable L4 service | Edge agents connect outbound to this endpoint for config, control, and telemetry. Hosted Standard routes this through the same Gateway data-plane Service as web traffic. |
| Agent artifact/download path | 50053 | TCP | `serviceradar-agent-gateway` | Same Gateway or L4 service as agent gateway when possible | Used by the gateway artifact path. Keep it paired with the agent gateway identity and firewall policy. |
| OTLP HTTP ingest | 443 | HTTPS | `serviceradar-otlp:4318` | Shared or dedicated Gateway route, DNS record, TLS certificate | Recommended external path for OTLP/HTTP because the Gateway can present a public certificate and forward plaintext in-cluster. |
| OTLP gRPC ingest | 50052 | TLS passthrough | `serviceradar-otlp:4317` | Shared or dedicated TLS Gateway listener with SNI routing | With passthrough, senders see the ServiceRadar collector certificate and must trust the ServiceRadar root CA or explicitly skip verification. |

The web, edge-agent TCP, and OTLP HTTP routes can share a public Gateway
data-plane address, but they still require separate listeners and routes. A web
`HTTPRoute` on `443` does not expose the edge-agent TCP service on `50052` or
`50053`. Alternatively, give `serviceradar-agent-gateway` its own L4
LoadBalancer and DNS name. OTLP gRPC can also share a Gateway listener if the
cloud/Gateway implementation supports TLS passthrough and SNI routing.

For Helm installs, keep the endpoint roles explicit:

- `webNg.host` and `webNg.publicUrl` name the public HTTPS web/API origin used
  during enrollment.
- `webNg.gatewayAddress` names the external `host:port` stored in the agent
  bundle for its post-enrollment gRPC session.
- `agentGateway.publicHostname` identifies the public gateway name used for
  artifact delivery. The certificate presented on the gateway ports must cover
  the hostname in `webNg.gatewayAddress`.
- `gatewayApi.agentGateway` renders the agent-gateway TCP routes; the parent
  Gateway still needs matching listeners in `attach` mode.

## Optional Telemetry Collectors

Provision these only for deployments that ingest telemetry directly from routers, switches, firewalls, SIEM forwarders, or similar external systems.

| Purpose | Public Port | Protocol | Kubernetes Backend | Cloud Resource Shape | Isolation Note |
|---|---:|---|---|---|---|
| Syslog UDP | 514 | UDP | `serviceradar-log-collector:514` | UDP Gateway listener or dedicated UDP load balancer | UDP has no hostname/SNI. Use a deployment-specific IP or a deployment-specific port when multiple deployments share infrastructure. |
| Syslog TCP | 514 | TCP | `serviceradar-log-collector-tcp:514` | TCP load balancer or Gateway TCP listener | Optional. Enable only when the deployment needs TCP syslog. |
| NetFlow | 2055 | UDP | `serviceradar-flow-collector:2055` | Gateway UDP listener, dedicated UDP load balancer, or routed private service | NetFlow v9 templates are exporter and collector scoped. Keep exporter affinity stable. |
| sFlow | 6343 | UDP | `serviceradar-flow-collector:6343` | Gateway UDP listener, dedicated UDP load balancer, or routed private service | Often shares the same collector address as NetFlow. |
| IPFIX alternate port | 4739 | UDP | `serviceradar-flow-collector:4739` | Gateway UDP listener, dedicated UDP load balancer, or routed private service | Optional. Enable only when exporters require the conventional IPFIX port. |
| SNMP traps | 162 | UDP | `serviceradar-trapd:162` | Gateway UDP listener, dedicated UDP load balancer, or routed private service | SNMP polling is outbound from agents; only traps need inbound UDP 162. |
| BGP BMP | 11019 | TCP | `serviceradar-bmp-collector:11019` | Gateway TCP listener, dedicated TCP load balancer, or routed private service | BMP sessions usually come from routers and should be tightly source-restricted. |

For UDP collectors, prefer a deployment-specific IP address when customers expect standard ports such as `514`, `162`, `2055`, or `6343`. A shared IP with unique ports can work operationally, but it requires customer device configuration that may be harder to standardize.

## Internal Only

These services should remain internal to the ServiceRadar namespace, the cluster, or the platform control plane:

| Service | Port | Reason |
|---|---:|---|
| `serviceradar-web-ng` | 4000 | Serve only behind Gateway/ingress. |
| `serviceradar-core` / core-elx | 8090, 50052, 9090 | Internal API, gRPC, and metrics paths. |
| `serviceradar-datasvc` | 50057 | Internal data service. |
| CNPG/PostgreSQL | 5432 | Database access; use private administration paths only. |
| NATS client, monitoring, and cluster ports | 4222, 8222, 6222 | Internal JetStream messaging. External NATS leaf-node access is platform infrastructure, not a default customer ingress. |
| ERTS distribution and epmd | 4369, 9100-9155 | Internal Erlang clustering only. |
| Collector management or metrics ports | varies | Expose through private monitoring only. |

Local development load balancers, direct database access services, and NATS debug access are not part of the baseline Kubernetes ingress model.

## Cloud Provisioning Checklist

For each deployment, decide which ingress entries are enabled and provision:

- DNS records for hostname-routed services.
- TLS certificates for public HTTPS termination.
- L4 load balancers or Gateway listeners for gRPC, TCP, and UDP services.
- Firewall, security group, or load-balancer source CIDR restrictions for collector traffic.
- Kubernetes `HTTPRoute`, `TLSRoute`, `UDPRoute`, or `Service` objects matching the chosen exposure model.
- NetworkPolicy rules that admit only the Gateway data plane or approved source CIDRs to the backend pods.

For Kubernetes-specific values and examples, see [Kubernetes External Ingestion](./kubernetes-ingestion.md). For a compact operator port reference, see [Service Port Map](./service-port-map.md).
