package k8sinventory

import (
	"testing"
	"time"
)

// Fixture values reused across the Gitsrv VIP cases below.
const (
	testEnvoyPodIP   = "192.0.2.40"
	testGitsrvSSHSvc = "gitsrv-ssh"
)

func TestBuildSnapshot_VIPOwnershipAndDNATHint(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 5, 16, 0, 0, 0, time.UTC)
	ready := true

	// A MetalLB VIP fronting an Envoy Service on 443/22, targetPorts
	// 10443/10022, with an EndpointSlice pointing at the envoy pod.
	in := BuildInput{
		ClusterID: "demo",
		Now:       now,
		Services: []ServiceView{
			{
				Namespace:             "envoy-gateway-system",
				Name:                  "envoy-gitsrv-gitsrv-gateway-1a2b3c4d",
				UID:                   "svc-uid-1",
				Type:                  "LoadBalancer",
				ExternalTrafficPolicy: "Local",
				Annotations: map[string]string{
					"metallb.io/loadBalancerIPs":                "198.51.100.10",
					"metallb.universe.tf/address-pool":          "k3s-pool",
					"metallb.io/ip-allocated-from-pool":         "k3s-pool",
					"external-dns.alpha.kubernetes.io/hostname": "",
				},
				Ports: []ServicePortView{
					{Name: "https-443", Port: 443, Protocol: "TCP", TargetPort: 10443},
					{Name: "tcp-22", Port: 22, Protocol: "TCP", TargetPort: 10022},
				},
				Ingress: []LoadBalancerIngressView{
					{IP: "198.51.100.10", IPMode: "VIP"},
				},
			},
			// Backend ClusterIP service for gitsrv-ssh (no public exposure itself).
			{
				Namespace: "gitsrv",
				Name:      testGitsrvSSHSvc,
				UID:       "svc-uid-ssh",
				Type:      "ClusterIP",
				Ports: []ServicePortView{
					{Name: "ssh", Port: 22, Protocol: "TCP", TargetPort: 22},
				},
			},
		},
		EndpointSlices: []EndpointSliceView{
			{
				Namespace: "envoy-gateway-system",
				Name:      "envoy-gitsrv-gitsrv-gateway-1a2b3c4d-abc",
				Labels:    map[string]string{"kubernetes.io/service-name": "envoy-gitsrv-gitsrv-gateway-1a2b3c4d"},
				Endpoints: []SliceEndpointView{
					{
						Addresses:    []string{testEnvoyPodIP},
						Ready:        &ready,
						NodeName:     "node-worker-3.example.com",
						PodNamespace: "envoy-gateway-system",
						PodName:      "envoy-gitsrv-gitsrv-gateway-1a2b3c4d-6d4c8b9f77-k2xqp",
					},
				},
				Ports: []SlicePortView{
					{Name: "https-443", Port: 10443, Protocol: "TCP"},
					{Name: "tcp-22", Port: 10022, Protocol: "TCP"},
				},
			},
			{
				Namespace: "gitsrv",
				Name:      "gitsrv-ssh-xyz",
				Labels:    map[string]string{"kubernetes.io/service-name": testGitsrvSSHSvc},
				Endpoints: []SliceEndpointView{
					{
						Addresses:    []string{"192.0.2.41"},
						Ready:        &ready,
						NodeName:     "node-worker-1.example.com",
						PodNamespace: "gitsrv",
						PodName:      "gitsrv-7b9c5d4f86-r4mts",
					},
				},
				Ports: []SlicePortView{
					{Name: "ssh", Port: 22, Protocol: "TCP"},
				},
			},
		},
		Gateways: []GatewayView{
			{
				Namespace:    "gitsrv",
				Name:         "gitsrv-gateway",
				UID:          "gw-uid",
				GatewayClass: "gitsrv-envoy",
				Listeners: []GatewayListenerView{
					{Name: "https-web", Port: 443, Protocol: "HTTPS", Hostname: "code.carverauto.dev"},
					{Name: "ssh", Port: 22, Protocol: "TCP"},
				},
				Addresses: []GatewayAddressView{
					{Type: "IPAddress", Value: "198.51.100.10"},
				},
				Annotations: map[string]string{
					"metallb.io/loadBalancerIPs": "198.51.100.10",
				},
			},
		},
		Routes: []RouteView{
			{
				Namespace: "gitsrv",
				Name:      testGitsrvSSHSvc,
				Kind:      "TCPRoute",
				ParentRefs: []ParentRefView{
					{Name: "gitsrv-gateway", Namespace: "gitsrv", SectionName: "ssh"},
				},
				Backends: []BackendRef{
					{Kind: "Service", Name: testGitsrvSSHSvc, Namespace: "gitsrv", Port: 22},
				},
			},
		},
	}

	snap := BuildSnapshot(in)

	if snap.ClusterID != "demo" {
		t.Fatalf("cluster_id: got %q", snap.ClusterID)
	}
	if len(snap.Endpoints) == 0 {
		t.Fatal("expected endpoints")
	}

	// Service-level ownership for VIP:22
	svcHits := FindByPublicAddr(snap.Endpoints, "198.51.100.10", "", 22)
	if len(svcHits) == 0 {
		t.Fatalf("no endpoints for 198.51.100.10:22; all=%v", summarizeEndpoints(snap.Endpoints))
	}

	var foundService, foundGatewayRoute bool
	for _, ep := range svcHits {
		if ep.ExposureClass == ExposureLoadBalancer && ep.ServiceName == "envoy-gitsrv-gitsrv-gateway-1a2b3c4d" {
			foundService = true
			if ep.ServiceTargetPort != 10022 {
				t.Errorf("service target port: want 10022 got %d", ep.ServiceTargetPort)
			}
			if ep.MetalLBPool != "k3s-pool" {
				t.Errorf("metallb pool: got %q", ep.MetalLBPool)
			}
			if len(ep.EndpointTargets) != 1 {
				t.Fatalf("expected 1 endpoint target for LB service, got %+v", ep.EndpointTargets)
			}
			t0 := ep.EndpointTargets[0]
			if t0.IP != testEnvoyPodIP || t0.Port != 10022 {
				t.Errorf("envoy target: got %s:%d", t0.IP, t0.Port)
			}
			if t0.PodName == "" || t0.NodeName != "node-worker-3.example.com" {
				t.Errorf("pod/node: got pod=%q node=%q", t0.PodName, t0.NodeName)
			}
		}
		if ep.ExposureClass == ExposureGateway && ep.RouteKind == "TCPRoute" && ep.RouteName == testGitsrvSSHSvc {
			foundGatewayRoute = true
			if ep.ListenerName != "ssh" {
				t.Errorf("listener: got %q", ep.ListenerName)
			}
			if len(ep.BackendRefs) != 1 || ep.BackendRefs[0].Name != testGitsrvSSHSvc {
				t.Errorf("backend refs: %+v", ep.BackendRefs)
			}
			// Gateway path should associate gitsrv-ssh EndpointSlice backends.
			if len(ep.EndpointTargets) == 0 {
				t.Errorf("expected gateway route endpoint targets for gitsrv-ssh")
			}
		}
	}
	if !foundService {
		t.Error("missing LoadBalancer service ownership for VIP:22")
	}
	if !foundGatewayRoute {
		t.Error("missing Gateway TCPRoute ownership for VIP:22")
	}

	// Correlation: public NetFlow dst VIP:22 → backend podIP:10022
	hints := FindHints(snap.Hints, "198.51.100.10", 22)
	if len(hints) == 0 {
		t.Fatal("expected correlation hints for 198.51.100.10:22")
	}
	var sawEnvoyDNAT bool
	for _, h := range hints {
		if h.BackendIP == testEnvoyPodIP && h.BackendPort == 10022 {
			sawEnvoyDNAT = true
			if h.PublicPort != 22 {
				t.Errorf("hint public port: %d", h.PublicPort)
			}
		}
	}
	if !sawEnvoyDNAT {
		t.Errorf("expected DNAT hint VIP:22 → 192.0.2.40:10022; hints=%+v", hints)
	}
}

func TestBuildSnapshot_HostnameOnlyCloudLB(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 8, 5, 16, 0, 0, 0, time.UTC)
	ready := true
	in := BuildInput{
		ClusterID: "eks-prod",
		Now:       now,
		Services: []ServiceView{
			{
				Namespace: "ingress",
				Name:      "nginx-lb",
				UID:       "svc-eks",
				Type:      "LoadBalancer",
				Ports: []ServicePortView{
					{Name: "https", Port: 443, Protocol: "TCP", TargetPort: 8443},
				},
				Ingress: []LoadBalancerIngressView{
					{Hostname: "a1b2c3.us-east-1.elb.amazonaws.com"},
				},
			},
		},
		EndpointSlices: []EndpointSliceView{
			{
				Namespace: "ingress",
				Name:      "nginx-lb-1",
				Labels:    map[string]string{"kubernetes.io/service-name": "nginx-lb"},
				Endpoints: []SliceEndpointView{{
					Addresses:    []string{"10.0.1.5"},
					Ready:        &ready,
					PodNamespace: "ingress",
					PodName:      "nginx-0",
					NodeName:     "ip-10-0-1-9",
				}},
				Ports: []SlicePortView{{Name: "https", Port: 8443, Protocol: "TCP"}},
			},
		},
	}

	snap := BuildSnapshot(in)
	hits := FindByPublicAddr(snap.Endpoints, "", "a1b2c3.us-east-1.elb.amazonaws.com", 443)
	if len(hits) != 1 {
		t.Fatalf("want 1 hostname endpoint, got %d (%v)", len(hits), summarizeEndpoints(snap.Endpoints))
	}
	if hits[0].IP != "" {
		t.Errorf("expected empty IP for hostname-only LB, got %q", hits[0].IP)
	}
	if hits[0].ServiceTargetPort != 8443 {
		t.Errorf("target port: %d", hits[0].ServiceTargetPort)
	}
	if len(hits[0].EndpointTargets) != 1 || hits[0].EndpointTargets[0].Port != 8443 {
		t.Errorf("targets: %+v", hits[0].EndpointTargets)
	}
}

func TestBuildSnapshot_ExternalIP(t *testing.T) {
	t.Parallel()

	in := BuildInput{
		ClusterID: "lab",
		Now:       time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC),
		Services: []ServiceView{
			{
				Namespace:   "default",
				Name:        "legacy",
				Type:        "ClusterIP",
				ExternalIPs: []string{"203.0.113.10"},
				Ports: []ServicePortView{
					{Port: 80, Protocol: "TCP", TargetPort: 8080},
				},
			},
		},
	}
	snap := BuildSnapshot(in)
	hits := FindByPublicAddr(snap.Endpoints, "203.0.113.10", "", 80)
	if len(hits) != 1 {
		t.Fatalf("got %d", len(hits))
	}
	if hits[0].ExposureClass != ExposureExternalIP {
		t.Errorf("class: %s", hits[0].ExposureClass)
	}
}

func TestBuildSnapshot_IgnoresClusterIPWithoutExternal(t *testing.T) {
	t.Parallel()

	in := BuildInput{
		ClusterID: "lab",
		Services: []ServiceView{
			{
				Namespace: "default",
				Name:      "internal",
				Type:      "ClusterIP",
				Ports:     []ServicePortView{{Port: 80, Protocol: "TCP", TargetPort: 80}},
			},
		},
	}
	snap := BuildSnapshot(in)
	if len(snap.Endpoints) != 0 {
		t.Fatalf("expected no public endpoints, got %v", summarizeEndpoints(snap.Endpoints))
	}
}

func TestSnapshotFromMemoryLister(t *testing.T) {
	t.Parallel()

	lister := &MemoryLister{
		Services: []ServiceView{{
			Namespace: "ns",
			Name:      "lb",
			Type:      "LoadBalancer",
			Ports:     []ServicePortView{{Port: 443, Protocol: "TCP", TargetPort: 8443}},
			Ingress:   []LoadBalancerIngressView{{IP: "198.51.100.1"}},
		}},
	}
	snap, err := SnapshotFromLister(t.Context(), lister, SnapshotOptions{
		ClusterID:        "c1",
		EnableGatewayAPI: true,
		Now:              time.Date(2026, 2, 2, 0, 0, 0, 0, time.UTC),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Endpoints) != 1 || snap.Endpoints[0].IP != "198.51.100.1" {
		t.Fatalf("snapshot: %+v", snap.Endpoints)
	}
}

func summarizeEndpoints(eps []Endpoint) []string {
	out := make([]string, 0, len(eps))
	for _, ep := range eps {
		out = append(out, ep.ExposureClass.String()+" "+ep.IP+ep.Hostname+":"+itoa(ep.Port)+" svc="+ep.ServiceName+" gw="+ep.GatewayName+"/"+ep.RouteName)
	}
	return out
}

func (c ExposureClass) String() string { return string(c) }

func itoa(v int32) string {
	if v == 0 {
		return "0"
	}
	// small local itoa to avoid strconv in test helper noise
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [12]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
