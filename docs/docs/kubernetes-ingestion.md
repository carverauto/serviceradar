---
sidebar_position: 9
title: Kubernetes External Ingestion
---

# Kubernetes External Ingestion

ServiceRadar can receive telemetry from routers, switches, firewalls, and other systems outside the Kubernetes cluster. Keep those external paths explicit: expose only the collector ports you use, restrict them to known management networks or exporter IPs, and leave service-to-service ports internal.

Use this guide with the [Helm configuration](./helm-configuration.md), [service port map](./service-port-map.md), [syslog guide](./syslog.md), [NetFlow guide](./netflow.md), and [SNMP guide](./snmp.md).

## Address Model

There are two supported Kubernetes exposure patterns:

| Pattern | Use For | Notes |
|---|---|---|
| Shared Gateway API listener | Syslog UDP 514 when a shared Envoy Gateway already owns the public address | Saves public IPs. The chart renders a `UDPRoute` to `serviceradar-log-collector`. |
| Dedicated collector service | NetFlow, sFlow, SNMP traps, BMP, and environments without a shared UDP Gateway | Uses `LoadBalancer` or `NodePort` on the collector service. Keep firewall and NetworkPolicy allow lists tight. |

The demo environment currently uses this public address map:

| Telemetry | Destination | Kubernetes Backend |
|---|---|---|
| Syslog | `23.138.124.5:514/UDP` | Shared Gateway listener `syslog-udp` to `serviceradar-log-collector:514` |
| NetFlow | `23.138.124.25:2055/UDP` | `serviceradar-flow-collector` LoadBalancer |
| sFlow | `23.138.124.25:6343/UDP` | `serviceradar-flow-collector` LoadBalancer |
| SNMP traps | `23.138.124.26:162/UDP` | `serviceradar-trapd` LoadBalancer |
| BMP | `23.138.124.27:11019/TCP` | `serviceradar-bmp-collector` LoadBalancer |

These addresses are demo-specific. Production installs should use addresses assigned by the local load balancer, cloud provider, or Gateway owner. "External" means traffic originates outside the Kubernetes pod network; it does not mean the port should be reachable from the internet.

## Syslog Through Shared Gateway

Syslog no longer needs a dedicated public LoadBalancer IP when a shared Envoy Gateway can expose UDP 514. The shared Gateway must have a UDP listener, and the ServiceRadar chart attaches a `UDPRoute` to that listener.

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
kubectl get udproute -n demo
kubectl describe udproute -n demo serviceradar-syslog
kubectl logs -n demo deploy/serviceradar-log-collector --since=10m
```

If the `UDPRoute` is not accepted, check the parent reference, listener `sectionName`, namespace labels, and whether the cluster has Gateway API UDPRoute CRDs installed.

## NetFlow And sFlow

NetFlow and sFlow use the flow collector service. In demo this stays on `23.138.124.25` because IPFIX and NetFlow v9 templates are scoped per exporter and collector process. The service uses a single collector replica plus `ClientIP` session affinity so one exporter keeps landing on the same parser instance.

Example values:

```yaml
flowCollector:
  enabled: true
  replicaCount: 1
  service:
    type: LoadBalancer
    loadBalancerIP: "23.138.124.25"
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

Do not move flow traffic to a shared UDP Gateway unless you have validated exporter affinity and template state behavior for that Gateway implementation.

## SNMP Traps And BMP

SNMP traps and BMP are optional external collectors. Enable only when devices are configured to send this telemetry.

```yaml
trapd:
  externalService:
    enabled: true
    loadBalancerIP: "23.138.124.26"

bmpCollector:
  enabled: true
  service:
    type: LoadBalancer
    loadBalancerIP: "23.138.124.27"
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
kubectl get svc -n demo serviceradar-flow-collector serviceradar-trapd serviceradar-bmp-collector
kubectl get gateway -n serviceradar-system serviceradar-shared-gateway
kubectl get udproute -n demo
kubectl get networkpolicy -n demo
```

Check collector pods:

```bash
kubectl logs -n demo deploy/serviceradar-log-collector --since=10m
kubectl logs -n demo deploy/serviceradar-flow-collector --since=10m
kubectl logs -n demo deploy/serviceradar-trapd --since=10m
```

For packet-level checks, run `tcpdump` on a node, Gateway pod, or collector pod that is expected to see the traffic. Confirm the device is sending to the current address: syslog to the shared Gateway address, and flow/trap/BMP traffic to the collector service address.
