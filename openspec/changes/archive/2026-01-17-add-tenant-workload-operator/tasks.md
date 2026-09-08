## 1. Implementation
- [x] 1.1 Define tenant lifecycle event schema and JetStream stream configuration.
- [x] 1.2 Emit tenant create/update/delete events from core-elx with tenant id/slug and desired workloads.
- [x] 1.3 Add platform bootstrap step to create the operator NATS account and store creds as a Kubernetes Secret.
- [x] 1.4 Implement the tenant workload operator (Go/controller-runtime) to subscribe to tenant events.
- [x] 1.5 Operator: request tenant artifacts from core (mTLS certs, NATS creds) and store as Secrets.
- [x] 1.6 Operator: reconcile per-tenant workloads (agent-gateway, serviceradar-zen) and cleanup on delete.
- [x] 1.7 Add Helm manifests/RBAC for operator deployment and configuration.
- [x] 1.8 Document k8s provisioning flow and Docker single-tenant behavior.
