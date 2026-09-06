// Package k8sinventory discovers public/edge Kubernetes endpoints
// (LoadBalancer Services, ExternalIPs, Gateway API) and builds
// ownership + backend association records for IR and later flow join.
//
// This package intentionally has no dependency on ServiceRadar core,
// NATS, or SRQL. Collectors can dump JSON for local validation; SR
// integration is a separate layer.
package k8sinventory

import "time"

// ExposureClass classifies how an endpoint is published.
type ExposureClass string

const (
	ExposureLoadBalancer ExposureClass = "LoadBalancer"
	ExposureGateway      ExposureClass = "Gateway"
	ExposureExternalIP   ExposureClass = "ExternalIP"
	ExposureNodePort     ExposureClass = "NodePort"
)

// Endpoint is one public or edge-facing listener identity.
type Endpoint struct {
	ClusterID string `json:"cluster_id"`

	// Identity: at least one of IP or Hostname is set.
	IP       string `json:"ip,omitempty"`
	Hostname string `json:"hostname,omitempty"`
	Port     int32  `json:"port"`
	Protocol string `json:"protocol"` // TCP, UDP, SCTP

	ExposureClass         ExposureClass `json:"exposure_class"`
	ExternalTrafficPolicy string        `json:"external_traffic_policy,omitempty"`
	MetalLBPool           string        `json:"metallb_pool,omitempty"`
	LoadBalancerIPMode    string        `json:"load_balancer_ip_mode,omitempty"`

	Namespace   string `json:"namespace"`
	ServiceName string `json:"service_name,omitempty"`
	ServiceUID  string `json:"service_uid,omitempty"`

	GatewayName  string `json:"gateway_name,omitempty"`
	GatewayClass string `json:"gateway_class,omitempty"`
	ListenerName string `json:"listener_name,omitempty"`
	RouteKind    string `json:"route_kind,omitempty"`
	RouteName    string `json:"route_name,omitempty"`

	// BackendRefs are Gateway/Service route targets (usually ClusterIP Services).
	BackendRefs []BackendRef `json:"backend_refs,omitempty"`

	// EndpointTargets are live backends from EndpointSlices (pod/node/port).
	EndpointTargets []EndpointTarget `json:"endpoint_targets,omitempty"`

	// ServiceTargetPort is the Service targetPort (numeric) for this listener when known.
	// Used for VIP:publicPort → podIP:targetPort association (DNAT hint).
	ServiceTargetPort int32  `json:"service_target_port,omitempty"`
	ServiceTargetName string `json:"service_target_name,omitempty"`

	// Selected annotations useful for IR (MetalLB pin, ExternalDNS, Argo tracking).
	Annotations map[string]string `json:"annotations,omitempty"`

	ObservedAt time.Time `json:"observed_at"`
}

// BackendRef is a route or service backend reference.
type BackendRef struct {
	Group     string `json:"group,omitempty"`
	Kind      string `json:"kind,omitempty"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
	Port      int32  `json:"port,omitempty"`
	Weight    int32  `json:"weight,omitempty"`
}

// EndpointTarget is a live backend address from an EndpointSlice.
type EndpointTarget struct {
	IP           string `json:"ip,omitempty"`
	Port         int32  `json:"port,omitempty"`
	Protocol     string `json:"protocol,omitempty"`
	PodNamespace string `json:"pod_namespace,omitempty"`
	PodName      string `json:"pod_name,omitempty"`
	NodeName     string `json:"node_name,omitempty"`
	Ready        bool   `json:"ready"`
}

// CorrelationHint maps a public VIP:port to backend socket identities
// that netprobe/process attribution may observe after kube-proxy/IPVS DNAT.
//
// Example: 198.51.100.10:22 → 192.0.2.40:10022 (envoy pod).
type CorrelationHint struct {
	PublicIP       string `json:"public_ip,omitempty"`
	PublicHostname string `json:"public_hostname,omitempty"`
	PublicPort     int32  `json:"public_port"`
	Protocol       string `json:"protocol"`

	BackendIP   string `json:"backend_ip,omitempty"`
	BackendPort int32  `json:"backend_port,omitempty"`

	PodNamespace string `json:"pod_namespace,omitempty"`
	PodName      string `json:"pod_name,omitempty"`
	NodeName     string `json:"node_name,omitempty"`

	// Owner summary for IR without a full Endpoint copy.
	Namespace   string        `json:"namespace,omitempty"`
	ServiceName string        `json:"service_name,omitempty"`
	GatewayName string        `json:"gateway_name,omitempty"`
	RouteKind   string        `json:"route_kind,omitempty"`
	RouteName   string        `json:"route_name,omitempty"`
	Exposure    ExposureClass `json:"exposure_class,omitempty"`
}

// Snapshot is a full inventory view at a point in time.
type Snapshot struct {
	ClusterID   string            `json:"cluster_id"`
	GeneratedAt time.Time         `json:"generated_at"`
	Endpoints   []Endpoint        `json:"endpoints"`
	Hints       []CorrelationHint `json:"correlation_hints"`
}

// NodeRoleControlPlane is the inventory role for Nodes with a control-plane
// or master role label. Every other Node is NodeRoleWorker.
const (
	NodeRoleControlPlane = "control-plane"
	NodeRoleWorker       = "worker"
)

// NodeInventory is one Kubernetes Node's current Ready/identity facts.
type NodeInventory struct {
	ClusterID      string    `json:"cluster_id"`
	Name           string    `json:"name"`
	UID            string    `json:"uid,omitempty"`
	Role           string    `json:"role"`
	Ready          bool      `json:"ready"`
	ReadyReason    string    `json:"ready_reason,omitempty"`
	ReadyMessage   string    `json:"ready_message,omitempty"`
	Unschedulable  bool      `json:"unschedulable"`
	InternalIP     string    `json:"internal_ip,omitempty"`
	ExternalIP     string    `json:"external_ip,omitempty"`
	KubeletVersion string    `json:"kubelet_version,omitempty"`
	OSImage        string    `json:"os_image,omitempty"`
	ObservedAt     time.Time `json:"observed_at"`
}

// NodeSnapshot is the current-state Node catalog published on inventory.k8s.nodes.
type NodeSnapshot struct {
	ClusterID   string          `json:"cluster_id"`
	GeneratedAt time.Time       `json:"generated_at"`
	Nodes       []NodeInventory `json:"nodes"`
}

// BuildInput is a pure in-memory view of cluster objects used by BuildSnapshot.
// Tests construct this directly; live collectors fill it from API list/watch.
type BuildInput struct {
	ClusterID string
	// Now overrides time for deterministic tests; zero uses time.Now().
	Now time.Time

	Services       []ServiceView
	EndpointSlices []EndpointSliceView
	Gateways       []GatewayView
	Routes         []RouteView
}

// ServiceView is the subset of corev1.Service needed for ownership.
type ServiceView struct {
	Namespace             string
	Name                  string
	UID                   string
	Type                  string // LoadBalancer, ClusterIP, NodePort, ExternalName
	ExternalTrafficPolicy string
	ExternalIPs           []string
	Ports                 []ServicePortView
	Ingress               []LoadBalancerIngressView
	Annotations           map[string]string
	Labels                map[string]string
}

// NodeView is the subset of corev1.Node needed for Ready inventory.
type NodeView struct {
	Name           string
	UID            string
	Labels         map[string]string
	Unschedulable  bool
	Ready          bool
	ReadyReason    string
	ReadyMessage   string
	InternalIP     string
	ExternalIP     string
	KubeletVersion string
	OSImage        string
}

// ServicePortView is a service port mapping.
type ServicePortView struct {
	Name       string
	Port       int32
	Protocol   string
	TargetPort int32  // numeric target only; 0 if named-only
	TargetName string // named targetPort when not numeric
	NodePort   int32
}

// LoadBalancerIngressView is one LB ingress address.
type LoadBalancerIngressView struct {
	IP       string
	Hostname string
	IPMode   string
}

// EndpointSliceView is the subset of discoveryv1.EndpointSlice needed for backends.
type EndpointSliceView struct {
	Namespace   string
	Name        string
	Labels      map[string]string // expects kubernetes.io/service-name
	AddressType string
	Endpoints   []SliceEndpointView
	Ports       []SlicePortView
}

// SliceEndpointView is one backend endpoint.
type SliceEndpointView struct {
	Addresses    []string
	Ready        *bool
	NodeName     string
	PodNamespace string
	PodName      string
}

// SlicePortView is an EndpointSlice port.
type SlicePortView struct {
	Name     string
	Port     int32
	Protocol string
}

// GatewayView is a Gateway API Gateway (typed subset / unstructured-normalized).
type GatewayView struct {
	Namespace    string
	Name         string
	UID          string
	GatewayClass string
	Listeners    []GatewayListenerView
	Addresses    []GatewayAddressView
	Annotations  map[string]string
	Labels       map[string]string
}

// GatewayListenerView is one Gateway listener.
type GatewayListenerView struct {
	Name     string
	Port     int32
	Protocol string // HTTP, HTTPS, TLS, TCP, UDP
	Hostname string
}

// GatewayAddressView is a Gateway status address.
type GatewayAddressView struct {
	Type  string // IPAddress, Hostname
	Value string
}

// RouteView is a Gateway API route (HTTPRoute, TCPRoute, …).
type RouteView struct {
	Namespace  string
	Name       string
	UID        string
	Kind       string // HTTPRoute, TCPRoute, UDPRoute, GRPCRoute, TLSRoute
	ParentRefs []ParentRefView
	Hostnames  []string
	Backends   []BackendRef
}

// ParentRefView attaches a route to a Gateway listener.
type ParentRefView struct {
	Namespace   string
	Name        string
	SectionName string // listener name when set
}
