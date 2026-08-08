package k8sinventory

import (
	"fmt"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// GatewayFromUnstructured normalizes a Gateway API Gateway object.
func GatewayFromUnstructured(obj *unstructured.Unstructured) (GatewayView, error) {
	if obj == nil {
		return GatewayView{}, errNilGateway
	}
	gw := GatewayView{
		Namespace:   obj.GetNamespace(),
		Name:        obj.GetName(),
		UID:         string(obj.GetUID()),
		Annotations: cloneStringMap(obj.GetAnnotations()),
		Labels:      cloneStringMap(obj.GetLabels()),
	}
	if gc, _, _ := unstructured.NestedString(obj.Object, "spec", "gatewayClassName"); gc != "" {
		gw.GatewayClass = gc
	}

	listeners, _, _ := unstructured.NestedSlice(obj.Object, "spec", "listeners")
	for _, raw := range listeners {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		lv := GatewayListenerView{
			Name:     asString(m["name"]),
			Protocol: asString(m["protocol"]),
			Hostname: asString(m["hostname"]),
		}
		if p, ok := asInt32(m["port"]); ok {
			lv.Port = p
		}
		gw.Listeners = append(gw.Listeners, lv)
	}

	addrs, _, _ := unstructured.NestedSlice(obj.Object, "status", "addresses")
	for _, raw := range addrs {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		gw.Addresses = append(gw.Addresses, GatewayAddressView{
			Type:  asString(m["type"]),
			Value: asString(m["value"]),
		})
	}
	return gw, nil
}

// RouteFromUnstructured normalizes HTTPRoute/TCPRoute/UDPRoute/GRPCRoute/TLSRoute.
func RouteFromUnstructured(obj *unstructured.Unstructured) (RouteView, error) {
	if obj == nil {
		return RouteView{}, errNilRoute
	}
	kind := obj.GetKind()
	r := RouteView{
		Namespace: obj.GetNamespace(),
		Name:      obj.GetName(),
		UID:       string(obj.GetUID()),
		Kind:      kind,
	}

	parentRefs, _, _ := unstructured.NestedSlice(obj.Object, "spec", "parentRefs")
	for _, raw := range parentRefs {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		pr := ParentRefView{
			Namespace:   asString(m["namespace"]),
			Name:        asString(m["name"]),
			SectionName: asString(m["sectionName"]),
		}
		r.ParentRefs = append(r.ParentRefs, pr)
	}

	if hosts, ok, _ := unstructured.NestedStringSlice(obj.Object, "spec", "hostnames"); ok {
		r.Hostnames = hosts
	}

	// rules[].backendRefs for HTTP/GRPC/TLS; TCP/UDP use rules[].backendRefs similarly in Gateway API.
	rules, _, _ := unstructured.NestedSlice(obj.Object, "spec", "rules")
	for _, rawRule := range rules {
		rule, ok := rawRule.(map[string]any)
		if !ok {
			continue
		}
		// HTTPRoute: backendRefs at rule level OR under backendRefs in some versions — standard is rule.backendRefs
		backendRefs, found, _ := unstructured.NestedSlice(rule, "backendRefs")
		if !found {
			// Some TCPRoute shapes: rules[].backendRefs is the same
			continue
		}
		for _, rawBR := range backendRefs {
			br, ok := rawBR.(map[string]any)
			if !ok {
				continue
			}
			ref := BackendRef{
				Group:     asString(br["group"]),
				Kind:      asString(br["kind"]),
				Namespace: asString(br["namespace"]),
				Name:      asString(br["name"]),
			}
			if ref.Kind == "" {
				ref.Kind = "Service"
			}
			if p, ok := asInt32(br["port"]); ok {
				ref.Port = p
			}
			if w, ok := asInt32(br["weight"]); ok {
				ref.Weight = w
			}
			r.Backends = append(r.Backends, ref)
		}
	}

	// TCPRoute early API sometimes nests backendRefs under rules only — already handled.
	// Also support top-level backendRefs if present (non-standard but harmless).
	if len(r.Backends) == 0 {
		if brs, ok, _ := unstructured.NestedSlice(obj.Object, "spec", "backendRefs"); ok {
			for _, rawBR := range brs {
				br, ok := rawBR.(map[string]any)
				if !ok {
					continue
				}
				ref := BackendRef{
					Group:     asString(br["group"]),
					Kind:      firstNonEmpty(asString(br["kind"]), "Service"),
					Namespace: asString(br["namespace"]),
					Name:      asString(br["name"]),
				}
				if p, ok := asInt32(br["port"]); ok {
					ref.Port = p
				}
				r.Backends = append(r.Backends, ref)
			}
		}
	}

	return r, nil
}

func asString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case fmt.Stringer:
		return t.String()
	default:
		return ""
	}
}

func asInt32(v any) (int32, bool) {
	switch t := v.(type) {
	case int32:
		return t, true
	case int64:
		return int32(t), true
	case int:
		return int32(t), true
	case float64:
		return int32(t), true
	case float32:
		return int32(t), true
	default:
		return 0, false
	}
}
