package k8sinventory

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestGatewayFromUnstructured(t *testing.T) {
	t.Parallel()

	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1",
		"kind":       "Gateway",
		"metadata": map[string]any{
			"name":      "gitsrv-gateway",
			"namespace": "gitsrv",
			"uid":       "gw-1",
		},
		"spec": map[string]any{
			"gatewayClassName": "gitsrv-envoy",
			"listeners": []any{
				map[string]any{"name": "ssh", "port": int64(22), "protocol": "TCP"},
				map[string]any{"name": "https-web", "port": int64(443), "protocol": "HTTPS", "hostname": "code.carverauto.dev"},
			},
		},
		"status": map[string]any{
			"addresses": []any{
				map[string]any{"type": "IPAddress", "value": "198.51.100.10"},
			},
		},
	}}

	gw, err := GatewayFromUnstructured(obj)
	if err != nil {
		t.Fatal(err)
	}
	if gw.Name != "gitsrv-gateway" || gw.GatewayClass != "gitsrv-envoy" {
		t.Fatalf("gateway: %+v", gw)
	}
	if len(gw.Listeners) != 2 || gw.Listeners[0].Port != 22 {
		t.Fatalf("listeners: %+v", gw.Listeners)
	}
	if len(gw.Addresses) != 1 || gw.Addresses[0].Value != "198.51.100.10" {
		t.Fatalf("addresses: %+v", gw.Addresses)
	}
}

func TestRouteFromUnstructured_TCPRoute(t *testing.T) {
	t.Parallel()

	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "gateway.networking.k8s.io/v1alpha2",
		"kind":       "TCPRoute",
		"metadata": map[string]any{
			"name":      "gitsrv-ssh",
			"namespace": "gitsrv",
		},
		"spec": map[string]any{
			"parentRefs": []any{
				map[string]any{
					"name":        "gitsrv-gateway",
					"namespace":   "gitsrv",
					"sectionName": "ssh",
				},
			},
			"rules": []any{
				map[string]any{
					"backendRefs": []any{
						map[string]any{
							"name": "gitsrv-ssh",
							"port": int64(22),
							"kind": "Service",
						},
					},
				},
			},
		},
	}}

	r, err := RouteFromUnstructured(obj)
	if err != nil {
		t.Fatal(err)
	}
	if r.Kind != "TCPRoute" || r.Name != "gitsrv-ssh" {
		t.Fatalf("route: %+v", r)
	}
	if len(r.ParentRefs) != 1 || r.ParentRefs[0].SectionName != "ssh" {
		t.Fatalf("parentRefs: %+v", r.ParentRefs)
	}
	if len(r.Backends) != 1 || r.Backends[0].Name != "gitsrv-ssh" || r.Backends[0].Port != 22 {
		t.Fatalf("backends: %+v", r.Backends)
	}
}
