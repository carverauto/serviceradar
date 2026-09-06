package k8sinventory

import (
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

// ServiceFromCore converts a corev1.Service into ServiceView.
func ServiceFromCore(svc *corev1.Service) ServiceView {
	if svc == nil {
		return ServiceView{}
	}
	out := ServiceView{
		Namespace:             svc.Namespace,
		Name:                  svc.Name,
		UID:                   string(svc.UID),
		Type:                  string(svc.Spec.Type),
		ExternalTrafficPolicy: string(svc.Spec.ExternalTrafficPolicy),
		ExternalIPs:           append([]string(nil), svc.Spec.ExternalIPs...),
		Annotations:           cloneStringMap(svc.Annotations),
		Labels:                cloneStringMap(svc.Labels),
	}
	for _, p := range svc.Spec.Ports {
		pv := ServicePortView{
			Name:     p.Name,
			Port:     p.Port,
			Protocol: string(p.Protocol),
			NodePort: p.NodePort,
		}
		switch p.TargetPort.Type {
		case intstr.Int:
			pv.TargetPort = p.TargetPort.IntVal
		case intstr.String:
			pv.TargetName = p.TargetPort.StrVal
		}
		if p.Protocol == "" {
			pv.Protocol = "TCP"
		}
		out.Ports = append(out.Ports, pv)
	}
	for _, ing := range svc.Status.LoadBalancer.Ingress {
		iv := LoadBalancerIngressView{
			IP:       ing.IP,
			Hostname: ing.Hostname,
		}
		if ing.IPMode != nil {
			iv.IPMode = string(*ing.IPMode)
		}
		out.Ingress = append(out.Ingress, iv)
	}
	return out
}

// EndpointSliceFromDiscovery converts a discoveryv1.EndpointSlice into EndpointSliceView.
func EndpointSliceFromDiscovery(es *discoveryv1.EndpointSlice) EndpointSliceView {
	if es == nil {
		return EndpointSliceView{}
	}
	out := EndpointSliceView{
		Namespace:   es.Namespace,
		Name:        es.Name,
		Labels:      cloneStringMap(es.Labels),
		AddressType: string(es.AddressType),
	}
	for _, ep := range es.Endpoints {
		sev := SliceEndpointView{
			Addresses: append([]string(nil), ep.Addresses...),
		}
		if ep.Conditions.Ready != nil {
			ready := *ep.Conditions.Ready
			sev.Ready = &ready
		}
		if ep.NodeName != nil {
			sev.NodeName = *ep.NodeName
		}
		if ep.TargetRef != nil && ep.TargetRef.Kind == "Pod" {
			sev.PodName = ep.TargetRef.Name
			sev.PodNamespace = ep.TargetRef.Namespace
			if sev.PodNamespace == "" {
				sev.PodNamespace = es.Namespace
			}
		}
		out.Endpoints = append(out.Endpoints, sev)
	}
	for _, p := range es.Ports {
		sp := SlicePortView{}
		if p.Name != nil {
			sp.Name = *p.Name
		}
		if p.Port != nil {
			sp.Port = *p.Port
		}
		if p.Protocol != nil {
			sp.Protocol = string(*p.Protocol)
		} else {
			sp.Protocol = "TCP"
		}
		out.Ports = append(out.Ports, sp)
	}
	return out
}

// NodeFromCore converts a corev1.Node into NodeView.
func NodeFromCore(node *corev1.Node) NodeView {
	if node == nil {
		return NodeView{}
	}
	out := NodeView{
		Name:           node.Name,
		UID:            string(node.UID),
		Labels:         cloneStringMap(node.Labels),
		Unschedulable:  node.Spec.Unschedulable,
		KubeletVersion: node.Status.NodeInfo.KubeletVersion,
		OSImage:        node.Status.NodeInfo.OSImage,
	}
	for _, cond := range node.Status.Conditions {
		if cond.Type != corev1.NodeReady {
			continue
		}
		out.Ready = cond.Status == corev1.ConditionTrue
		out.ReadyReason = cond.Reason
		out.ReadyMessage = cond.Message
		break
	}
	for _, addr := range node.Status.Addresses {
		switch addr.Type {
		case corev1.NodeInternalIP:
			if out.InternalIP == "" {
				out.InternalIP = addr.Address
			}
		case corev1.NodeExternalIP:
			if out.ExternalIP == "" {
				out.ExternalIP = addr.Address
			}
		case corev1.NodeHostName, corev1.NodeInternalDNS, corev1.NodeExternalDNS:
			// DNS names are not IP addresses; node identity comes from metadata.Name.
		}
	}
	return out
}

func cloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
