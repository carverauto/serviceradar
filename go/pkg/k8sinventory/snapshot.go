package k8sinventory

import (
	"context"
	"fmt"
	"sync"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

// SnapshotOptions controls live cluster listing.
type SnapshotOptions struct {
	ClusterID string
	// Namespaces limits Service/EndpointSlice/Gateway listing. Empty = all namespaces.
	Namespaces []string
	// EnableGatewayAPI lists Gateway API routes when true (default true).
	EnableGatewayAPI bool
	// Now overrides snapshot time in tests.
	Now time.Time
}

// DefaultSnapshotOptions returns options with Gateway API enabled.
func DefaultSnapshotOptions(clusterID string) SnapshotOptions {
	return SnapshotOptions{
		ClusterID:        clusterID,
		EnableGatewayAPI: true,
	}
}

// Lister abstracts Kubernetes list operations for tests.
type Lister interface {
	ListServices(ctx context.Context, namespace string) ([]ServiceView, error)
	ListEndpointSlices(ctx context.Context, namespace string) ([]EndpointSliceView, error)
	ListGateways(ctx context.Context, namespace string) ([]GatewayView, error)
	ListRoutes(ctx context.Context, namespace string) ([]RouteView, error)
	ListNodes(ctx context.Context) ([]NodeView, error)
}

// ClientLister implements Lister using client-go typed + dynamic clients.
type ClientLister struct {
	Client  kubernetes.Interface
	Dynamic dynamic.Interface
	// GatewayAPI enables Gateway API dynamic lists.
	GatewayAPI bool
}

// Gateway API group, and the two versions its resources are split across: the Gateway and
// HTTPRoute/GRPCRoute kinds graduated to v1, while the L4 route kinds are still v1alpha2.
const (
	gatewayAPIGroup     = "gateway.networking.k8s.io"
	gatewayAPIVersionV1 = "v1"
	gatewayAPIVersionL4 = "v1alpha2"
)

// GroupVersionResource is a struct, so these cannot be consts. Building them on demand keeps
// them out of package-level mutable state -- a shared var would let any caller reassign the
// GVR every list in this package resolves through.
func gvrGateways() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: gatewayAPIGroup, Version: gatewayAPIVersionV1, Resource: "gateways"}
}

// gvrRoutes returns every route kind to enumerate, in the order they are listed.
func gvrRoutes() []schema.GroupVersionResource {
	return []schema.GroupVersionResource{
		{Group: gatewayAPIGroup, Version: gatewayAPIVersionV1, Resource: "httproutes"},
		{Group: gatewayAPIGroup, Version: gatewayAPIVersionV1, Resource: "grpcroutes"},
		{Group: gatewayAPIGroup, Version: gatewayAPIVersionL4, Resource: "tlsroutes"},
		{Group: gatewayAPIGroup, Version: gatewayAPIVersionL4, Resource: "tcproutes"},
		{Group: gatewayAPIGroup, Version: gatewayAPIVersionL4, Resource: "udproutes"},
	}
}

func (l *ClientLister) ListServices(ctx context.Context, namespace string) ([]ServiceView, error) {
	if l.Client == nil {
		return nil, errKubeClientNil
	}
	list, err := l.Client.CoreV1().Services(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	out := make([]ServiceView, 0, len(list.Items))
	for i := range list.Items {
		out = append(out, ServiceFromCore(&list.Items[i]))
	}
	return out, nil
}

func (l *ClientLister) ListNodes(ctx context.Context) ([]NodeView, error) {
	if l.Client == nil {
		return nil, errKubeClientNil
	}
	list, err := l.Client.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	out := make([]NodeView, 0, len(list.Items))
	for i := range list.Items {
		out = append(out, NodeFromCore(&list.Items[i]))
	}
	return out, nil
}

func (l *ClientLister) ListEndpointSlices(ctx context.Context, namespace string) ([]EndpointSliceView, error) {
	if l.Client == nil {
		return nil, errKubeClientNil
	}
	list, err := l.Client.DiscoveryV1().EndpointSlices(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	out := make([]EndpointSliceView, 0, len(list.Items))
	for i := range list.Items {
		out = append(out, EndpointSliceFromDiscovery(&list.Items[i]))
	}
	return out, nil
}

func (l *ClientLister) ListGateways(ctx context.Context, namespace string) ([]GatewayView, error) {
	if !l.GatewayAPI || l.Dynamic == nil {
		return nil, nil
	}
	list, err := l.Dynamic.Resource(gvrGateways()).Namespace(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		// CRD may be missing — treat as empty for optional Gateway API.
		return nil, fmt.Errorf("list gateways: %w", err)
	}
	out := make([]GatewayView, 0, len(list.Items))
	for i := range list.Items {
		gw, err := GatewayFromUnstructured(&list.Items[i])
		if err != nil {
			continue
		}
		out = append(out, gw)
	}
	return out, nil
}

func (l *ClientLister) ListRoutes(ctx context.Context, namespace string) ([]RouteView, error) {
	if !l.GatewayAPI || l.Dynamic == nil {
		return nil, nil
	}
	var out []RouteView
	for _, gvr := range gvrRoutes() {
		list, err := l.Dynamic.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{})
		if err != nil {
			// Individual route CRDs may be absent; skip.
			continue
		}
		for i := range list.Items {
			r, err := RouteFromUnstructured(&list.Items[i])
			if err != nil {
				continue
			}
			out = append(out, r)
		}
	}
	return out, nil
}

// SnapshotFromLister builds a Snapshot by listing objects through Lister.
func SnapshotFromLister(ctx context.Context, lister Lister, opts SnapshotOptions) (Snapshot, error) {
	if opts.ClusterID == "" {
		return Snapshot{}, errClusterIDRequired
	}
	if lister == nil {
		return Snapshot{}, errListerNil
	}

	namespaces := opts.Namespaces
	if len(namespaces) == 0 {
		namespaces = []string{metav1.NamespaceAll}
	}

	var in BuildInput
	in.ClusterID = opts.ClusterID
	in.Now = opts.Now

	for _, ns := range namespaces {
		svcs, err := lister.ListServices(ctx, ns)
		if err != nil {
			return Snapshot{}, fmt.Errorf("list services in %q: %w", ns, err)
		}
		in.Services = append(in.Services, svcs...)

		slices, err := lister.ListEndpointSlices(ctx, ns)
		if err != nil {
			return Snapshot{}, fmt.Errorf("list endpointslices in %q: %w", ns, err)
		}
		in.EndpointSlices = append(in.EndpointSlices, slices...)

		if opts.EnableGatewayAPI {
			// Gateway API CRDs may be absent; soft-fail so Service inventory still works.
			if gws, err := lister.ListGateways(ctx, ns); err == nil {
				in.Gateways = append(in.Gateways, gws...)
			}
			if routes, err := lister.ListRoutes(ctx, ns); err == nil {
				in.Routes = append(in.Routes, routes...)
			}
		}
	}

	return BuildSnapshot(in), nil
}

// NodeSnapshotFromLister lists cluster Nodes once (namespace allow-lists do not apply).
func NodeSnapshotFromLister(ctx context.Context, lister Lister, opts SnapshotOptions) (NodeSnapshot, error) {
	if opts.ClusterID == "" {
		return NodeSnapshot{}, errClusterIDRequired
	}
	if lister == nil {
		return NodeSnapshot{}, errListerNil
	}
	nodes, err := lister.ListNodes(ctx)
	if err != nil {
		return NodeSnapshot{}, fmt.Errorf("list nodes: %w", err)
	}
	return BuildNodeSnapshot(opts.ClusterID, opts.Now, nodes), nil
}

// MemoryLister is a test double that returns fixed objects.
//
// A Controller lists from its own goroutine, so a test that changes what the lister returns
// while the Controller runs is a concurrent writer. Mutating an element in place --
// `lister.Services[0].Ports[0].Port = 8080` -- races the read in endpointsFromService, because
// ListServices hands back the stored slice and both sides then touch the same backing array.
// Use SetServices for that: it swaps the whole slice under the lock, so a reader already
// holding the previous one keeps observing a value nobody writes to again.
type MemoryLister struct {
	mu             sync.RWMutex
	Services       []ServiceView
	EndpointSlices []EndpointSliceView
	Gateways       []GatewayView
	Routes         []RouteView
	Nodes          []NodeView
}

// SetServices replaces the service list. Safe to call while a Controller is running.
func (m *MemoryLister) SetServices(services []ServiceView) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.Services = services
}

func (m *MemoryLister) ListServices(context.Context, string) ([]ServiceView, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.Services, nil
}
func (m *MemoryLister) ListEndpointSlices(context.Context, string) ([]EndpointSliceView, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.EndpointSlices, nil
}
func (m *MemoryLister) ListGateways(context.Context, string) ([]GatewayView, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.Gateways, nil
}
func (m *MemoryLister) ListRoutes(context.Context, string) ([]RouteView, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.Routes, nil
}
func (m *MemoryLister) ListNodes(context.Context) ([]NodeView, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.Nodes, nil
}
