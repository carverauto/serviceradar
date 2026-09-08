package k8sinventory

import (
	"sort"
	"strings"
	"time"
)

const (
	annotationMetalLBPool      = "metallb.universe.tf/address-pool"
	annotationMetalLBIPs       = "metallb.io/loadBalancerIPs"
	annotationMetalLBAllocated = "metallb.io/ip-allocated-from-pool"
	labelServiceName           = "kubernetes.io/service-name"

	// L4 protocols as they are stored. Kubernetes defaults an unset port protocol to TCP,
	// and every Gateway listener protocol except UDP rides on TCP.
	protocolTCP = "TCP"
	protocolUDP = "UDP"
)

// BuildSnapshot derives public endpoints and correlation hints from an
// in-memory object set. No Kubernetes API or ServiceRadar I/O.
func BuildSnapshot(in BuildInput) Snapshot {
	now := in.Now
	if now.IsZero() {
		now = time.Now().UTC()
	}

	slicesByService := indexEndpointSlices(in.EndpointSlices)
	routesByGateway := indexRoutesByGateway(in.Routes)

	var endpoints []Endpoint

	for _, svc := range in.Services {
		endpoints = append(endpoints, endpointsFromService(in.ClusterID, now, svc, slicesByService)...)
	}

	for _, gw := range in.Gateways {
		endpoints = append(endpoints, endpointsFromGateway(in.ClusterID, now, gw, routesByGateway[gatewayKey(gw.Namespace, gw.Name)], slicesByService)...)
	}

	endpoints = dedupeEndpoints(endpoints)
	sortEndpoints(endpoints)

	hints := BuildCorrelationHints(endpoints)
	sortHints(hints)

	return Snapshot{
		ClusterID:   in.ClusterID,
		GeneratedAt: now,
		Endpoints:   endpoints,
		Hints:       hints,
	}
}

// BuildCorrelationHints maps each public endpoint to backend pod sockets
// when EndpointTargets (and/or ServiceTargetPort) are known.
func BuildCorrelationHints(endpoints []Endpoint) []CorrelationHint {
	var hints []CorrelationHint
	for _, ep := range endpoints {
		if len(ep.EndpointTargets) == 0 {
			// Still emit a port-level hint with service target port only when present.
			if ep.ServiceTargetPort > 0 && (ep.IP != "" || ep.Hostname != "") {
				hints = append(hints, CorrelationHint{
					PublicIP:       ep.IP,
					PublicHostname: ep.Hostname,
					PublicPort:     ep.Port,
					Protocol:       ep.Protocol,
					BackendPort:    ep.ServiceTargetPort,
					Namespace:      ep.Namespace,
					ServiceName:    ep.ServiceName,
					GatewayName:    ep.GatewayName,
					RouteKind:      ep.RouteKind,
					RouteName:      ep.RouteName,
					Exposure:       ep.ExposureClass,
				})
			}
			continue
		}
		for _, t := range ep.EndpointTargets {
			backendPort := t.Port
			if backendPort == 0 {
				backendPort = ep.ServiceTargetPort
			}
			hints = append(hints, CorrelationHint{
				PublicIP:       ep.IP,
				PublicHostname: ep.Hostname,
				PublicPort:     ep.Port,
				Protocol:       ep.Protocol,
				BackendIP:      t.IP,
				BackendPort:    backendPort,
				PodNamespace:   t.PodNamespace,
				PodName:        t.PodName,
				NodeName:       t.NodeName,
				Namespace:      ep.Namespace,
				ServiceName:    ep.ServiceName,
				GatewayName:    ep.GatewayName,
				RouteKind:      ep.RouteKind,
				RouteName:      ep.RouteName,
				Exposure:       ep.ExposureClass,
			})
		}
	}
	return hints
}

func endpointsFromService(clusterID string, now time.Time, svc ServiceView, slices map[string][]EndpointSliceView) []Endpoint {
	var out []Endpoint

	var addresses []struct {
		ip, hostname, ipMode string
		class                ExposureClass
	}

	if strings.EqualFold(svc.Type, "LoadBalancer") {
		for _, ing := range svc.Ingress {
			if ing.IP == "" && ing.Hostname == "" {
				continue
			}
			addresses = append(addresses, struct {
				ip, hostname, ipMode string
				class                ExposureClass
			}{ing.IP, ing.Hostname, ing.IPMode, ExposureLoadBalancer})
		}
	}

	for _, ext := range svc.ExternalIPs {
		if ext == "" {
			continue
		}
		addresses = append(addresses, struct {
			ip, hostname, ipMode string
			class                ExposureClass
		}{ext, "", "", ExposureExternalIP})
	}

	if len(addresses) == 0 {
		return nil
	}

	svcSlices := slices[serviceKey(svc.Namespace, svc.Name)]
	ann := selectAnnotations(svc.Annotations)
	pool := firstNonEmpty(svc.Annotations[annotationMetalLBAllocated], svc.Annotations[annotationMetalLBPool])

	for _, addr := range addresses {
		for _, p := range svc.Ports {
			proto := normalizeProtocol(p.Protocol)
			targets := matchSliceTargets(svcSlices, p, proto)
			ep := Endpoint{
				ClusterID:             clusterID,
				IP:                    addr.ip,
				Hostname:              addr.hostname,
				Port:                  p.Port,
				Protocol:              proto,
				ExposureClass:         addr.class,
				ExternalTrafficPolicy: svc.ExternalTrafficPolicy,
				MetalLBPool:           pool,
				LoadBalancerIPMode:    addr.ipMode,
				Namespace:             svc.Namespace,
				ServiceName:           svc.Name,
				ServiceUID:            svc.UID,
				EndpointTargets:       targets,
				ServiceTargetPort:     p.TargetPort,
				ServiceTargetName:     p.TargetName,
				Annotations:           ann,
				ObservedAt:            now,
			}
			out = append(out, ep)
		}
	}
	return out
}

func endpointsFromGateway(
	clusterID string,
	now time.Time,
	gw GatewayView,
	routes []RouteView,
	slices map[string][]EndpointSliceView,
) []Endpoint {
	if len(gw.Addresses) == 0 || len(gw.Listeners) == 0 {
		return nil
	}

	var out []Endpoint
	ann := selectAnnotations(gw.Annotations)
	pool := firstNonEmpty(gw.Annotations[annotationMetalLBAllocated], gw.Annotations[annotationMetalLBPool])

	for _, addr := range gw.Addresses {
		ip, hostname := splitGatewayAddress(addr)
		if ip == "" && hostname == "" {
			continue
		}
		for _, listener := range gw.Listeners {
			proto := gatewayListenerToL4(listener.Protocol)
			matchedRoutes := routesForListener(routes, gw, listener.Name)
			if len(matchedRoutes) == 0 {
				// Still record the listener as a public endpoint without route detail.
				out = append(out, Endpoint{
					ClusterID:     clusterID,
					IP:            ip,
					Hostname:      hostname,
					Port:          listener.Port,
					Protocol:      proto,
					ExposureClass: ExposureGateway,
					MetalLBPool:   pool,
					Namespace:     gw.Namespace,
					GatewayName:   gw.Name,
					GatewayClass:  gw.GatewayClass,
					ListenerName:  listener.Name,
					Annotations:   ann,
					ObservedAt:    now,
				})
				continue
			}
			for _, route := range matchedRoutes {
				backends := route.Backends
				// Attach EndpointSlice targets for Service backends.
				var targets []EndpointTarget
				var serviceTargetPort int32
				var serviceTargetName string
				var serviceName, serviceUID string
				for _, b := range backends {
					if b.Kind != "" && !strings.EqualFold(b.Kind, "Service") {
						continue
					}
					ns := b.Namespace
					if ns == "" {
						ns = route.Namespace
					}
					svcSlices := slices[serviceKey(ns, b.Name)]
					// Prefer matching slice ports to backend port.
					sp := ServicePortView{Port: b.Port, Protocol: proto, TargetPort: b.Port}
					targets = append(targets, matchSliceTargets(svcSlices, sp, proto)...)
					if serviceName == "" {
						serviceName = b.Name
						serviceTargetPort = b.Port
					}
					// If slice has a single port matching backend, capture target port from slice.
					for _, sl := range svcSlices {
						for _, p := range sl.Ports {
							if b.Port == 0 || p.Port == b.Port || p.Name != "" {
								if serviceTargetPort == 0 && p.Port > 0 {
									serviceTargetPort = p.Port
								}
							}
						}
					}
					_ = serviceUID
					_ = serviceTargetName
				}
				// Dedupe targets
				targets = dedupeTargets(targets)

				out = append(out, Endpoint{
					ClusterID:         clusterID,
					IP:                ip,
					Hostname:          hostname,
					Port:              listener.Port,
					Protocol:          proto,
					ExposureClass:     ExposureGateway,
					MetalLBPool:       pool,
					Namespace:         gw.Namespace,
					ServiceName:       serviceName,
					GatewayName:       gw.Name,
					GatewayClass:      gw.GatewayClass,
					ListenerName:      listener.Name,
					RouteKind:         route.Kind,
					RouteName:         route.Name,
					BackendRefs:       backends,
					EndpointTargets:   targets,
					ServiceTargetPort: serviceTargetPort,
					Annotations:       ann,
					ObservedAt:        now,
				})
			}
		}
	}
	return out
}

func splitGatewayAddress(addr GatewayAddressView) (ip, hostname string) {
	switch strings.ToLower(addr.Type) {
	case "ipaddress", "ip", "":
		// Empty type: treat as IP if it looks like one, else hostname.
		if looksLikeIP(addr.Value) {
			return addr.Value, ""
		}
		if strings.EqualFold(addr.Type, "Hostname") {
			return "", addr.Value
		}
		if looksLikeIP(addr.Value) {
			return addr.Value, ""
		}
		return "", addr.Value
	case "hostname":
		return "", addr.Value
	default:
		if looksLikeIP(addr.Value) {
			return addr.Value, ""
		}
		return "", addr.Value
	}
}

func looksLikeIP(s string) bool {
	if s == "" {
		return false
	}
	// Cheap check: dots or colons, no spaces.
	if strings.Contains(s, " ") {
		return false
	}
	return strings.Contains(s, ".") || strings.Contains(s, ":")
}

func gatewayListenerToL4(proto string) string {
	switch strings.ToUpper(proto) {
	case protocolUDP:
		return protocolUDP
	case protocolTCP, "TLS", "HTTP", "HTTPS", "GRPC":
		return protocolTCP
	default:
		if proto == "" {
			return protocolTCP
		}
		return strings.ToUpper(proto)
	}
}

func routesForListener(routes []RouteView, gw GatewayView, listenerName string) []RouteView {
	var out []RouteView
	for _, r := range routes {
		for _, p := range r.ParentRefs {
			refNS := p.Namespace
			if refNS == "" {
				refNS = r.Namespace
			}
			if refNS != gw.Namespace || p.Name != gw.Name {
				continue
			}
			if p.SectionName == "" || p.SectionName == listenerName {
				out = append(out, r)
				break
			}
		}
	}
	return out
}

func matchSliceTargets(slices []EndpointSliceView, port ServicePortView, proto string) []EndpointTarget {
	var out []EndpointTarget
	for _, sl := range slices {
		// Determine which slice ports apply.
		type portHit struct {
			port  int32
			proto string
		}
		var hits []portHit
		for _, sp := range sl.Ports {
			spProto := normalizeProtocol(sp.Protocol)
			if proto != "" && spProto != "" && spProto != proto {
				continue
			}
			// Match by name or by target port number or by service port number.
			if port.TargetName != "" && sp.Name == port.TargetName {
				hits = append(hits, portHit{sp.Port, spProto})
				continue
			}
			if port.TargetPort > 0 && sp.Port == port.TargetPort {
				hits = append(hits, portHit{sp.Port, spProto})
				continue
			}
			if port.Port > 0 && sp.Port == port.Port {
				hits = append(hits, portHit{sp.Port, spProto})
				continue
			}
			// A BackendRef-style port -- Port set, TargetPort equal to it, slice listing only a
			// container port -- needs no branch here: the `sp.Port == port.Port` case above
			// already matched it, and the TargetPort sweep below covers the rest.
		}
		// If no port filter matched but slice has ports and we have a target port, use all slice ports that equal target.
		if len(hits) == 0 && port.TargetPort > 0 {
			for _, sp := range sl.Ports {
				if sp.Port == port.TargetPort {
					hits = append(hits, portHit{sp.Port, normalizeProtocol(sp.Protocol)})
				}
			}
		}
		// If still empty and only one port on slice, use it (common for single-port services).
		if len(hits) == 0 && len(sl.Ports) == 1 {
			hits = append(hits, portHit{sl.Ports[0].Port, normalizeProtocol(sl.Ports[0].Protocol)})
		}
		// Backend ref port that matches slice port directly (Gateway path uses backend port = service port).
		if len(hits) == 0 {
			for _, sp := range sl.Ports {
				if port.Port > 0 && sp.Port == port.Port {
					hits = append(hits, portHit{sp.Port, normalizeProtocol(sp.Protocol)})
				}
			}
		}

		for _, ep := range sl.Endpoints {
			ready := true
			if ep.Ready != nil {
				ready = *ep.Ready
			}
			for _, addr := range ep.Addresses {
				if len(hits) == 0 {
					out = append(out, EndpointTarget{
						IP:           addr,
						Port:         port.TargetPort,
						Protocol:     proto,
						PodNamespace: ep.PodNamespace,
						PodName:      ep.PodName,
						NodeName:     ep.NodeName,
						Ready:        ready,
					})
					continue
				}
				for _, h := range hits {
					out = append(out, EndpointTarget{
						IP:           addr,
						Port:         h.port,
						Protocol:     firstNonEmpty(h.proto, proto),
						PodNamespace: ep.PodNamespace,
						PodName:      ep.PodName,
						NodeName:     ep.NodeName,
						Ready:        ready,
					})
				}
			}
		}
	}
	return dedupeTargets(out)
}

func indexEndpointSlices(slices []EndpointSliceView) map[string][]EndpointSliceView {
	out := make(map[string][]EndpointSliceView)
	for _, sl := range slices {
		svcName := ""
		if sl.Labels != nil {
			svcName = sl.Labels[labelServiceName]
		}
		if svcName == "" {
			continue
		}
		key := serviceKey(sl.Namespace, svcName)
		out[key] = append(out[key], sl)
	}
	return out
}

func indexRoutesByGateway(routes []RouteView) map[string][]RouteView {
	out := make(map[string][]RouteView)
	for _, r := range routes {
		seen := map[string]struct{}{}
		for _, p := range r.ParentRefs {
			ns := p.Namespace
			if ns == "" {
				ns = r.Namespace
			}
			key := gatewayKey(ns, p.Name)
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			out[key] = append(out[key], r)
		}
	}
	return out
}

func serviceKey(ns, name string) string { return ns + "/" + name }
func gatewayKey(ns, name string) string { return ns + "/" + name }

func normalizeProtocol(p string) string {
	if p == "" {
		return protocolTCP
	}
	return strings.ToUpper(p)
}

func selectAnnotations(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	keys := []string{
		annotationMetalLBPool,
		annotationMetalLBIPs,
		annotationMetalLBAllocated,
		"external-dns.alpha.kubernetes.io/hostname",
		"argocd.argoproj.io/tracking-id",
	}
	out := map[string]string{}
	for _, k := range keys {
		if v, ok := in[k]; ok && v != "" {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func dedupeTargets(in []EndpointTarget) []EndpointTarget {
	if len(in) <= 1 {
		return in
	}
	type key struct {
		ip, pod, node string
		port          int32
	}
	seen := map[key]struct{}{}
	var out []EndpointTarget
	for _, t := range in {
		k := key{t.IP, t.PodNamespace + "/" + t.PodName, t.NodeName, t.Port}
		if _, ok := seen[k]; ok {
			continue
		}
		seen[k] = struct{}{}
		out = append(out, t)
	}
	return out
}

func dedupeEndpoints(in []Endpoint) []Endpoint {
	if len(in) <= 1 {
		return in
	}
	type key struct {
		ip, host, proto, ns, svc, gw, listener, routeKind, routeName string
		port                                                         int32
		class                                                        ExposureClass
	}
	seen := map[key]int{}
	var out []Endpoint
	for _, ep := range in {
		k := key{
			ep.IP, ep.Hostname, ep.Protocol, ep.Namespace, ep.ServiceName,
			ep.GatewayName, ep.ListenerName, ep.RouteKind, ep.RouteName,
			ep.Port, ep.ExposureClass,
		}
		if idx, ok := seen[k]; ok {
			// Prefer entry with more backend detail.
			if len(ep.EndpointTargets) > len(out[idx].EndpointTargets) ||
				(ep.RouteName != "" && out[idx].RouteName == "") {
				out[idx] = ep
			}
			continue
		}
		seen[k] = len(out)
		out = append(out, ep)
	}
	return out
}

func sortEndpoints(eps []Endpoint) {
	sort.SliceStable(eps, func(i, j int) bool {
		a, b := eps[i], eps[j]
		if a.IP != b.IP {
			return a.IP < b.IP
		}
		if a.Hostname != b.Hostname {
			return a.Hostname < b.Hostname
		}
		if a.Port != b.Port {
			return a.Port < b.Port
		}
		if a.Protocol != b.Protocol {
			return a.Protocol < b.Protocol
		}
		if a.Namespace != b.Namespace {
			return a.Namespace < b.Namespace
		}
		return a.ServiceName+"/"+a.GatewayName+"/"+a.RouteName < b.ServiceName+"/"+b.GatewayName+"/"+b.RouteName
	})
}

func sortHints(hints []CorrelationHint) {
	sort.SliceStable(hints, func(i, j int) bool {
		a, b := hints[i], hints[j]
		if a.PublicIP != b.PublicIP {
			return a.PublicIP < b.PublicIP
		}
		if a.PublicPort != b.PublicPort {
			return a.PublicPort < b.PublicPort
		}
		if a.BackendIP != b.BackendIP {
			return a.BackendIP < b.BackendIP
		}
		return a.BackendPort < b.BackendPort
	})
}

// FindByPublicAddr returns endpoints matching IP or hostname (and optional port).
// port == 0 means any port.
func FindByPublicAddr(eps []Endpoint, ip, hostname string, port int32) []Endpoint {
	var out []Endpoint
	for _, ep := range eps {
		if ip != "" && ep.IP != ip {
			continue
		}
		if hostname != "" && ep.Hostname != hostname {
			continue
		}
		if port != 0 && ep.Port != port {
			continue
		}
		out = append(out, ep)
	}
	return out
}

// FindHints maps a public flow destination to backend socket candidates.
func FindHints(hints []CorrelationHint, publicIP string, publicPort int32) []CorrelationHint {
	var out []CorrelationHint
	for _, h := range hints {
		if publicIP != "" && h.PublicIP != publicIP {
			continue
		}
		if publicPort != 0 && h.PublicPort != publicPort {
			continue
		}
		out = append(out, h)
	}
	return out
}
