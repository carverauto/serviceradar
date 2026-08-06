package k8sinventory

import (
	"context"
	"fmt"
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
}

// ClientLister implements Lister using client-go typed + dynamic clients.
type ClientLister struct {
	Client  kubernetes.Interface
	Dynamic dynamic.Interface
	// GatewayAPI enables Gateway API dynamic lists.
	GatewayAPI bool
}

// gateway API GVRs (standard channel).
var (
	gvrGateway   = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gateways"}
	gvrHTTPRoute = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "httproutes"}
	gvrGRPCRoute = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "grpcroutes"}
	gvrTLSRoute  = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1alpha2", Resource: "tlsroutes"}
	gvrTCPRoute  = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1alpha2", Resource: "tcproutes"}
	gvrUDPRoute  = schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1alpha2", Resource: "udproutes"}
)

func (l *ClientLister) ListServices(ctx context.Context, namespace string) ([]ServiceView, error) {
	if l.Client == nil {
		return nil, fmt.Errorf("kubernetes client is nil")
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

func (l *ClientLister) ListEndpointSlices(ctx context.Context, namespace string) ([]EndpointSliceView, error) {
	if l.Client == nil {
		return nil, fmt.Errorf("kubernetes client is nil")
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
	list, err := l.Dynamic.Resource(gvrGateway).Namespace(namespace).List(ctx, metav1.ListOptions{})
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
	for _, gvr := range []schema.GroupVersionResource{gvrHTTPRoute, gvrGRPCRoute, gvrTLSRoute, gvrTCPRoute, gvrUDPRoute} {
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
		return Snapshot{}, fmt.Errorf("cluster_id is required")
	}
	if lister == nil {
		return Snapshot{}, fmt.Errorf("lister is nil")
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

// MemoryLister is a test double that returns fixed objects.
type MemoryLister struct {
	Services       []ServiceView
	EndpointSlices []EndpointSliceView
	Gateways       []GatewayView
	Routes         []RouteView
}

func (m *MemoryLister) ListServices(context.Context, string) ([]ServiceView, error) {
	return m.Services, nil
}
func (m *MemoryLister) ListEndpointSlices(context.Context, string) ([]EndpointSliceView, error) {
	return m.EndpointSlices, nil
}
func (m *MemoryLister) ListGateways(context.Context, string) ([]GatewayView, error) {
	return m.Gateways, nil
}
func (m *MemoryLister) ListRoutes(context.Context, string) ([]RouteView, error) {
	return m.Routes, nil
}
