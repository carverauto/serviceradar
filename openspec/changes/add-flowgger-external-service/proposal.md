# Change: Add Configurable External Service for Flowgger Syslog Ingestion

## Why

Flowgger receives syslog traffic (UDP/TCP) from external network devices. Currently, exposing flowgger externally requires manually creating LoadBalancer services outside the Helm chart. Users need a way to configure external access through the Helm chart with support for various load balancer implementations (MetalLB, cloud providers, etc.).

## What Changes

- **Helm chart**: Add optional external service configuration for flowgger with configurable:
  - Service type (LoadBalancer, NodePort, ClusterIP)
  - Annotations (for MetalLB address pools, cloud LB settings, etc.)
  - Port mappings (external ports for syslog UDP/TCP)
  - Load balancer IP (optional static IP assignment)
- **Docker Compose**: Document port exposure configuration for syslog traffic
- **K8s manifests**: Update demo-staging to use helm values instead of manual external service YAML

## Impact

- Affected code: `helm/serviceradar/templates/flowgger.yaml`, `helm/serviceradar/values.yaml`, `k8s/demo/staging/`
- Affected services: flowgger deployment
- Breaking changes: None (additive feature, disabled by default)
- Users can now configure external syslog access entirely through helm values
