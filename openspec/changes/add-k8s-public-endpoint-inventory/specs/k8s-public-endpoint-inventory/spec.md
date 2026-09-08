## ADDED Requirements

### Requirement: Public endpoint inventory capability
The system SHALL provide a Kubernetes public endpoint inventory capability that maps public or edge-facing addresses (IP and/or hostname) and ports to owning Service and/or Gateway API resources without requiring operators to run kubectl.

#### Scenario: IR lookup by public VIP
- **WHEN** an operator queries inventory for IP `23.138.124.7`
- **THEN** the system returns the owning LoadBalancer Service and/or Gateway identity, exposed ports, and related route/backend summary for that cluster

#### Scenario: Lookup by port narrows listeners
- **WHEN** an operator queries inventory for IP `23.138.124.7` and port `22` protocol TCP
- **THEN** the system returns the SSH listener path (Gateway listener and/or Service port) rather than unrelated ports on the same VIP

### Requirement: Dedicated cluster-plane collector without host-agent API access
The system SHALL collect public endpoint inventory using a dedicated in-cluster inventory process that holds the Kubernetes API credentials for this feature. Node agents, netprobe, and workload-identity collectors MUST NOT be granted Kubernetes API access for public endpoint inventory.

#### Scenario: Host agent has no inventory kube credentials
- **WHEN** public endpoint inventory is enabled in a cluster
- **THEN** host-installed ServiceRadar agents continue to operate without a Kubernetes ServiceAccount token for apiserver inventory watches

#### Scenario: Inventory process is the API client
- **WHEN** public endpoint inventory is enabled
- **THEN** only the inventory Deployment (or equivalent few-replica cluster-plane process) uses a ServiceAccount bound to inventory read RBAC

### Requirement: Least-privilege read-only RBAC
The inventory ServiceAccount SHALL be limited to get, list, and watch on the resources required for ownership discovery (Services, EndpointSlices, and configured Gateway API resources). The inventory ServiceAccount MUST NOT receive permissions to read Secrets, create or update arbitrary cluster objects, or use pod exec or node proxy subresources.

#### Scenario: RBAC excludes secrets
- **WHEN** the Helm chart renders inventory RBAC with default settings
- **THEN** the Role or ClusterRole does not include `secrets` resources

#### Scenario: RBAC is read-only verbs
- **WHEN** the Helm chart renders inventory RBAC with default settings
- **THEN** verbs are limited to get, list, and watch for watched inventory resources

### Requirement: Dataplane-agnostic ownership sources
The inventory collector SHALL derive ownership from Kubernetes API objects (Service status and specs, EndpointSlices, Gateway API status and routes) and MUST NOT require a specific kube-proxy mode (IPVS, iptables, or nftables) or CNI as a precondition for ownership discovery.

#### Scenario: Ownership works without IPVS-specific signals
- **WHEN** a LoadBalancer Service reports an ingress IP or hostname in `status.loadBalancer.ingress`
- **THEN** the inventory records that endpoint regardless of whether the node dataplane is IPVS or iptables-based

#### Scenario: Gateway address ownership
- **WHEN** a Gateway reports an address in `status.addresses` and has programmed listeners
- **THEN** the inventory records listener ports and associated accepted routes when Gateway API informers are enabled

### Requirement: IP and hostname endpoint identities
The inventory SHALL store endpoint identities as IP, hostname, or both when present on Service or Gateway status, so managed cloud load balancers that expose hostnames without static IPs can still be inventoried.

#### Scenario: Hostname-only load balancer ingress
- **WHEN** a Service LoadBalancer ingress entry contains a hostname and no IP
- **THEN** the inventory persists the hostname and leaves IP null or unset rather than dropping the endpoint

#### Scenario: IP pin with MetalLB
- **WHEN** a Service or Gateway path exposes a concrete IP (including MetalLB-assigned VIP)
- **THEN** the inventory persists the IP for exact-match IR queries

### Requirement: Optional Helm deployment
The ServiceRadar Helm chart SHALL ship Kubernetes public endpoint inventory as an optional component disabled by default, and SHALL allow demo or production values files to enable it explicitly.

#### Scenario: Default chart does not deploy inventory
- **WHEN** the chart is installed with default values and `k8sInventory.enabled` is false or unset as false
- **THEN** no inventory Deployment or inventory ClusterRole is created for this component

#### Scenario: Demo values enable inventory
- **WHEN** `values-demo.yaml` (or equivalent demo values) sets `k8sInventory.enabled` true with a cluster identifier
- **THEN** the chart renders the inventory Deployment, ServiceAccount, and read-only RBAC for the demo cluster

### Requirement: Graceful degradation when optional CRDs are missing
When Gateway API or optional Envoy Gateway CRDs are not installed, the inventory collector SHALL disable the corresponding informers and continue Service and EndpointSlice inventory rather than crash-looping.

#### Scenario: Missing EnvoyProxy CRD
- **WHEN** EnvoyProxy CRD discovery is enabled in config but the CRD is absent from the cluster
- **THEN** the collector logs or metrics the missing CRD and continues other watches without process exit

### Requirement: Current-state persistence and soft-delete
The system SHALL persist inventory as current-state rows keyed by cluster and endpoint identity, updating on watch events and soft-deleting or tombstoning endpoints that disappear after a successful resync generation.

#### Scenario: Service VIP reassignment
- **WHEN** a LoadBalancer IP moves from Service A to Service B
- **THEN** inventory no longer attributes that IP to Service A after resync and attributes it to Service B

### Requirement: Support tier documentation
The system documentation SHALL state which environments are tested versus supported-but-untested versus experimental for public endpoint inventory, including that managed cloud (EKS, GKE, AKS, Tanzu and similar) paths may be experimental until validated.

#### Scenario: Docs declare demo tested path
- **WHEN** an operator reads the public endpoint inventory documentation
- **THEN** the docs identify the ServiceRadar demo k3s + MetalLB + Gateway API path as the tested configuration and mark untested cloud providers accordingly

### Requirement: DNAT process correlation is out of scope for initial inventory
The initial public endpoint inventory release MUST NOT require implementing NetFlow-to-process DNAT correlation. Inventory MAY record backend target ports to enable a future correlator, but process attribution join behavior is not required for acceptance of ownership inventory.

#### Scenario: Ownership available without attributed_flows join
- **WHEN** only inventory and NetFlow are healthy and process DNAT join is not implemented
- **THEN** operators can still resolve VIP ownership via inventory queries
