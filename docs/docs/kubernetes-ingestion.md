---
sidebar_position: 9
title: Kubernetes External Ingestion
---

# Kubernetes External Ingestion

ServiceRadar can receive telemetry from routers, switches, firewalls, and other systems outside the Kubernetes cluster. Keep those external paths explicit: expose only the collector ports you use, restrict them to known management networks or exporter IPs, and leave service-to-service ports internal.

Use this guide with the [Helm configuration](./helm-configuration.md), [Kubernetes ingress services](./service-ports.md), [service port map](./service-port-map.md), [syslog guide](./syslog.md), [NetFlow guide](./netflow.md), and [SNMP guide](./snmp.md).

## Address Model

There are two supported Kubernetes exposure patterns:

| Pattern | Use For | Notes |
|---|---|---|
| Shared Gateway API listener | Syslog UDP 514, edge-agent TCP, and deployments that deliberately consolidate flow, SNMP trap, or BMP ingress behind a Gateway-owned address | Avoids allocating a separate collector address. The chart renders `UDPRoute`/`TCPRoute` objects to the internal collector Services and NetworkPolicies that admit only the Gateway data-plane namespace. |
| Dedicated collector service | Environments without a shared UDP/TCP Gateway or sites that need collector-specific addresses | Uses an internal `LoadBalancer`, private `NodePort`, or equivalent routed service on the collector. Keep firewall and NetworkPolicy allow lists tight. |

Use a private deployment address map like this in your site runbook:

| Telemetry | Destination | Kubernetes Backend |
|---|---|---|
| Syslog | `<GATEWAY_OR_SYSLOG_ADDRESS>:514/UDP` | Shared Gateway listener `syslog-udp` to `serviceradar-log-collector:514`, or a dedicated syslog service |
| NetFlow | `<GATEWAY_OR_FLOW_ADDRESS>:2055/UDP` | Gateway listener `netflow` or `serviceradar-flow-collector` service |
| sFlow | `<GATEWAY_OR_FLOW_ADDRESS>:6343/UDP` | Gateway listener `sflow` or `serviceradar-flow-collector` service |
| SNMP traps | `<GATEWAY_OR_TRAP_ADDRESS>:162/UDP` | Gateway listener `snmp-traps` or `serviceradar-trapd` service |
| BMP | `<GATEWAY_OR_BMP_ADDRESS>:11019/TCP` | Gateway listener `bmp` or `serviceradar-bmp-collector` service |

Keep the actual addresses in private operations material. "External" means traffic originates outside the Kubernetes pod network; it does not mean the port should be reachable from the internet.

### Preserve Device Source Addresses

ServiceRadar records the source address observed by the collector in
`logs.source_ip`. A direct `LoadBalancer` or `NodePort` path should use
`externalTrafficPolicy: Local` when the Kubernetes provider supports it and
when the service has a local endpoint on the receiving node. This asks the
service proxy to preserve the client address, but it can reduce failover
options and requires health-aware scheduling.

Gateway API and external load balancers can still rewrite the source address.
If syslog records show the Gateway or load balancer address instead of the
router address, ask the Tanzu or load balancer administrators to preserve the
client source address and to disable source NAT for the syslog listener where
supported. NetworkPolicy cannot restore an address that was already rewritten.
The collector preserves the address it actually receives and cannot infer the
original device address from the syslog payload.

For source-fidelity-sensitive syslog, use the dedicated collector Service
instead of a Gateway UDPRoute:

```yaml
logCollector:
  externalService:
    enabled: true
    type: LoadBalancer
    externalTrafficPolicy: Local
    annotations:
      metallb.universe.tf/address-pool: <ADDRESS_POOL>
    loadBalancerIP: "<SYSLOG_COLLECTOR_ADDRESS>"
```

Configure the device to send to that Service address on UDP/514. Do not use a
shared Envoy Gateway UDP address when the collector must display the device's
transport source address: the standard Envoy Gateway UDP path is not
transparent and the backend observes the proxy address. A transparent proxy
requires separate network and proxy support; it cannot be enabled by changing
the ServiceRadar collector or NetworkPolicy.

## Syslog Through Shared Gateway

Syslog no longer needs a dedicated collector address when a shared Envoy Gateway can expose UDP 514 on the trusted network. The shared Gateway must have a UDP listener, and the ServiceRadar chart attaches a `UDPRoute` to that listener.

Example values:

```yaml
gatewayApi:
  enabled: true
  mode: attach
  syslog:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: serviceradar-shared-gateway
        namespace: serviceradar-system
        sectionName: syslog-udp
```

The Gateway owner must provide a listener similar to:

```yaml
listeners:
  - name: syslog-udp
    port: 514
    protocol: UDP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            serviceradar.com/gateway-access: "true"
```

The ServiceRadar namespace must match the Gateway listener's `allowedRoutes` selector. The chart renders the route to `serviceradar-log-collector:514` by default.

Verify the route:

```bash
kubectl get gateway -n serviceradar-system serviceradar-shared-gateway
kubectl get udproute -n serviceradar
kubectl describe udproute -n serviceradar serviceradar-syslog
kubectl logs -n serviceradar deploy/serviceradar-log-collector --since=10m
```

If the `UDPRoute` is not accepted, check the parent reference, listener `sectionName`, namespace labels, and whether the cluster has Gateway API UDPRoute CRDs installed.

## NetFlow And sFlow

NetFlow and sFlow use the flow collector service. Keep flow exports on a stable collector address because IPFIX and NetFlow v9 templates are scoped per exporter and collector process. The service should use a single collector replica plus `ClientIP` session affinity so one exporter keeps landing on the same parser instance.

Example values:

```yaml
flowCollector:
  enabled: true
  replicaCount: 1
  service:
    type: LoadBalancer
    loadBalancerIP: "<FLOW_COLLECTOR_ADDRESS>"
    externalTrafficPolicy: Local
    sessionAffinity: ClientIP
    ports:
      netflow:
        enabled: true
        port: 2055
        protocol: UDP
      sflow:
        enabled: true
        port: 6343
        protocol: UDP
```

Flow traffic can also ride Gateway API when the Gateway implementation preserves enough connection affinity for exporter/template state and the cloud edge can enforce the same trusted-source restrictions:

```yaml
gatewayApi:
  enabled: true
  flowCollector:
    enabled: true
    netflow:
      enabled: true
    sflow:
      enabled: true

flowCollector:
  enabled: true
  service:
    type: ClusterIP
```

Keep the dedicated service pattern when exporter affinity, UDP listener support, or source restriction behavior is uncertain.

## SNMP Traps And BMP

SNMP traps and BMP are optional external collectors. Enable only when devices are configured to send this telemetry.

```yaml
trapd:
  externalService:
    enabled: true
    loadBalancerIP: "<TRAP_COLLECTOR_ADDRESS>"

bmpCollector:
  enabled: true
  service:
    type: LoadBalancer
    loadBalancerIP: "<BMP_COLLECTOR_ADDRESS>"
```

These collectors can also use Gateway API and remain internal Services:

```yaml
gatewayApi:
  enabled: true
  trapd:
    enabled: true
  bmpCollector:
    enabled: true

trapd:
  externalService:
    enabled: false

bmpCollector:
  enabled: true
  service:
    type: ClusterIP
```

SNMP polling is different: agents and gateways initiate outbound UDP 161 requests to devices, so it usually does not require an inbound public service. SNMP traps are inbound UDP 162 and do require a reachable collector address.

## NetworkPolicy

When `networkPolicy.enabled=true`, Kubernetes NetworkPolicy can block external collectors even when Services and Gateways are correct. The chart creates dedicated ingress policies for externally exposed collectors so opening one telemetry port does not expose unrelated pods.

Use narrow CIDRs for production:

```yaml
networkPolicy:
  enabled: true
  ingress:
    flowCollectorExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
    logCollectorExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
    trapdExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
    bmpCollectorExternal:
      enabled: true
      allowedCIDRs:
        - "10.0.0.0/8"
```

For Gateway-routed syslog, also allow the Gateway data-plane namespace in the ordinary ingress policy because the packets arrive at `serviceradar-log-collector` from Envoy Gateway pods, not directly from the router source IP:

```yaml
networkPolicy:
  ingress:
    allowedNamespaces:
      - serviceradar-system
      - envoy-gateway-system
```

Keep perimeter firewall rules in place even when Kubernetes NetworkPolicy is broad. NetworkPolicy is a pod-level control; it is not a substitute for edge firewall policy.

## Operational Checks

Check the exposure layer:

```bash
kubectl get svc -n serviceradar serviceradar-flow-collector serviceradar-trapd serviceradar-bmp-collector
kubectl get gateway -n serviceradar-system serviceradar-shared-gateway
kubectl get udproute -n serviceradar
kubectl get networkpolicy -n serviceradar
```

Check collector pods:

```bash
kubectl logs -n serviceradar deploy/serviceradar-log-collector --since=10m
kubectl logs -n serviceradar deploy/serviceradar-flow-collector --since=10m
kubectl logs -n serviceradar deploy/serviceradar-trapd --since=10m
```

For packet-level checks, run `tcpdump` on a node, Gateway pod, or collector pod that is expected to see the traffic. Confirm the device is sending to the current address: syslog to the shared Gateway address, and flow/trap/BMP traffic to the collector service address.
