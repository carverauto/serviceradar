package k8sinventory

import (
	"context"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"
)

func TestServiceFromCore_LoadBalancerAndTargetPort(t *testing.T) {
	t.Parallel()

	ipMode := corev1.LoadBalancerIPModeVIP
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "envoy-svc",
			Namespace: "envoy-gateway-system",
			UID:       "uid-1",
			Annotations: map[string]string{
				"metallb.io/loadBalancerIPs": "198.51.100.10",
			},
		},
		Spec: corev1.ServiceSpec{
			Type:                  corev1.ServiceTypeLoadBalancer,
			ExternalTrafficPolicy: corev1.ServiceExternalTrafficPolicyLocal,
			Ports: []corev1.ServicePort{
				{Name: "tcp-22", Port: 22, Protocol: corev1.ProtocolTCP, TargetPort: intstr.FromInt32(10022)},
			},
		},
		Status: corev1.ServiceStatus{
			LoadBalancer: corev1.LoadBalancerStatus{
				Ingress: []corev1.LoadBalancerIngress{{IP: "198.51.100.10", IPMode: &ipMode}},
			},
		},
	}
	view := ServiceFromCore(svc)
	if view.Type != "LoadBalancer" || len(view.Ingress) != 1 || view.Ingress[0].IP != "198.51.100.10" {
		t.Fatalf("view: %+v", view)
	}
	if view.Ports[0].TargetPort != 10022 {
		t.Fatalf("target port: %+v", view.Ports[0])
	}
}

func TestSnapshotFromFakeClients_EndToEnd(t *testing.T) {
	t.Parallel()

	ready := true
	ipMode := corev1.LoadBalancerIPModeVIP

	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "envoy-gitsrv",
			Namespace: "envoy-gateway-system",
			UID:       "svc-1",
			Annotations: map[string]string{
				"metallb.universe.tf/address-pool": "k3s-pool",
			},
		},
		Spec: corev1.ServiceSpec{
			Type: corev1.ServiceTypeLoadBalancer,
			Ports: []corev1.ServicePort{
				{Name: "tcp-22", Port: 22, Protocol: corev1.ProtocolTCP, TargetPort: intstr.FromInt32(10022)},
				{Name: "https", Port: 443, Protocol: corev1.ProtocolTCP, TargetPort: intstr.FromInt32(10443)},
			},
		},
		Status: corev1.ServiceStatus{
			LoadBalancer: corev1.LoadBalancerStatus{
				Ingress: []corev1.LoadBalancerIngress{{IP: "198.51.100.10", IPMode: &ipMode}},
			},
		},
	}

	protoTCP := corev1.ProtocolTCP
	port10022 := int32(10022)
	port10443 := int32(10443)
	name22 := "tcp-22"
	name443 := "https"
	node := "node-worker-3.example.com"
	es := &discoveryv1.EndpointSlice{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "envoy-gitsrv-abc",
			Namespace: "envoy-gateway-system",
			Labels:    map[string]string{"kubernetes.io/service-name": "envoy-gitsrv"},
		},
		AddressType: discoveryv1.AddressTypeIPv4,
		Endpoints: []discoveryv1.Endpoint{{
			Addresses:  []string{"192.0.2.40"},
			Conditions: discoveryv1.EndpointConditions{Ready: &ready},
			NodeName:   &node,
			TargetRef: &corev1.ObjectReference{
				Kind:      "Pod",
				Name:      "envoy-pod",
				Namespace: "envoy-gateway-system",
			},
		}},
		Ports: []discoveryv1.EndpointPort{
			{Name: &name22, Port: &port10022, Protocol: &protoTCP},
			{Name: &name443, Port: &port10443, Protocol: &protoTCP},
		},
	}

	kube := fake.NewSimpleClientset(svc, es)

	gw := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1",
		"kind":       "Gateway",
		"metadata": map[string]any{
			"name":      "gitsrv-gateway",
			"namespace": "gitsrv",
		},
		"spec": map[string]any{
			"gatewayClassName": "gitsrv-envoy",
			"listeners": []any{
				map[string]any{"name": "ssh", "port": int64(22), "protocol": "TCP"},
			},
		},
		"status": map[string]any{
			"addresses": []any{
				map[string]any{"type": "IPAddress", "value": "198.51.100.10"},
			},
		},
	}}
	route := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1alpha2",
		"kind":       "TCPRoute",
		"metadata": map[string]any{
			"name":      "gitsrv-ssh",
			"namespace": "gitsrv",
		},
		"spec": map[string]any{
			"parentRefs": []any{
				map[string]any{"name": "gitsrv-gateway", "namespace": "gitsrv", "sectionName": "ssh"},
			},
			"rules": []any{
				map[string]any{
					"backendRefs": []any{
						map[string]any{"name": "gitsrv-ssh", "port": int64(22), "kind": "Service"},
					},
				},
			},
		},
	}}

	scheme := runtime.NewScheme()
	// dynamic fake needs list kinds registered for list operations
	dyn := dynamicfake.NewSimpleDynamicClient(scheme, gw, route)

	// Dynamic fake List may not work without list GVK registration for custom resources.
	// Use hybrid: typed fake for service/slice; Memory-style for gateway via custom lister.
	lister := &hybridLister{
		ClientLister: ClientLister{Client: kube, Dynamic: dyn, GatewayAPI: false},
		gateways: []GatewayView{{
			Namespace:    "gitsrv",
			Name:         "gitsrv-gateway",
			GatewayClass: "gitsrv-envoy",
			Listeners:    []GatewayListenerView{{Name: "ssh", Port: 22, Protocol: "TCP"}},
			Addresses:    []GatewayAddressView{{Type: "IPAddress", Value: "198.51.100.10"}},
		}},
		routes: []RouteView{{
			Namespace:  "gitsrv",
			Name:       "gitsrv-ssh",
			Kind:       "TCPRoute",
			ParentRefs: []ParentRefView{{Name: "gitsrv-gateway", Namespace: "gitsrv", SectionName: "ssh"}},
			Backends:   []BackendRef{{Kind: "Service", Name: "gitsrv-ssh", Port: 22}},
		}},
	}

	// Also prove pure convert path from typed objects works inside BuildSnapshot via lister services.
	snap, err := SnapshotFromLister(context.Background(), lister, SnapshotOptions{
		ClusterID:        "demo",
		EnableGatewayAPI: true,
		Now:              time.Date(2026, 8, 5, 0, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}

	hits := FindByPublicAddr(snap.Endpoints, "198.51.100.10", "", 22)
	if len(hits) == 0 {
		t.Fatalf("no VIP:22 endpoints: %v", summarizeEndpoints(snap.Endpoints))
	}

	var sawLB bool
	for _, ep := range hits {
		if ep.ServiceName == "envoy-gitsrv" && ep.ExposureClass == ExposureLoadBalancer {
			sawLB = true
			if len(ep.EndpointTargets) != 1 || ep.EndpointTargets[0].IP != "192.0.2.40" || ep.EndpointTargets[0].Port != 10022 {
				t.Fatalf("LB targets: %+v", ep.EndpointTargets)
			}
		}
	}
	if !sawLB {
		t.Fatalf("missing LB service ownership; endpoints=%v", summarizeEndpoints(hits))
	}

	hints := FindHints(snap.Hints, "198.51.100.10", 22)
	found := false
	for _, h := range hints {
		if h.BackendIP == "192.0.2.40" && h.BackendPort == 10022 {
			found = true
		}
	}
	if !found {
		t.Fatalf("missing correlation hint; hints=%+v", hints)
	}

	// Silence unused import if compiler complains about dynamic.Interface usage via field.
	var _ dynamic.Interface = dyn
}

// hybridLister uses typed fake clients for Service/EndpointSlice and in-memory Gateway API.
type hybridLister struct {
	ClientLister
	gateways []GatewayView
	routes   []RouteView
}

func (h *hybridLister) ListGateways(context.Context, string) ([]GatewayView, error) {
	return h.gateways, nil
}
func (h *hybridLister) ListRoutes(context.Context, string) ([]RouteView, error) {
	return h.routes, nil
}
