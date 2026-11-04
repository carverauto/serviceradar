/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"bytes"
	"encoding/json"
	"errors"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errK8sPublicEndpointsPayloadNotObject = errors.New("k8s public endpoints payload is not a JSON object")

// k8sPublicEndpointsSnapshotFromJSON converts a k8s public endpoints JSON
// snapshot envelope (as returned by K8sPublicEndpointsSpoolService.GetStatus)
// into its typed edge protobuf message.
func k8sPublicEndpointsSnapshotFromJSON(raw []byte, agentID string) (*edgev1.K8SPublicEndpointsSnapshotV1, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var payload map[string]interface{}
	if err := dec.Decode(&payload); err != nil || payload == nil {
		return nil, errK8sPublicEndpointsPayloadNotObject
	}

	schemaVersion := payloadString(payload, "schema_version")
	if schemaVersion == "" {
		schemaVersion = K8sPublicEndpointsSchemaVersion
	}
	resolvedAgentID := payloadString(payload, "agent_id")
	if agentID != "" {
		resolvedAgentID = agentID
	}
	generatedAt := payloadString(payload, "generated_at")
	if generatedAt == "" {
		generatedAt = payloadString(payload, "snapshot_at")
	}

	snap := &edgev1.K8SPublicEndpointsSnapshotV1{
		SchemaVersion: schemaVersion,
		AgentId:       resolvedAgentID,
		ClusterId:     payloadString(payload, "cluster_id"),
		GeneratedAt:   generatedAt,
		ContentHash:   payloadString(payload, "content_hash"),
	}

	for _, rawEp := range payloadList(payload, "endpoints") {
		ep, ok := rawEp.(map[string]interface{})
		if !ok || ep == nil {
			continue
		}
		snap.Endpoints = append(snap.Endpoints, k8sPublicEndpointFromMap(ep))
	}

	for _, rawHint := range payloadList(payload, "correlation_hints") {
		hint, ok := rawHint.(map[string]interface{})
		if !ok || hint == nil {
			continue
		}
		snap.CorrelationHints = append(snap.CorrelationHints, k8sCorrelationHintFromMap(hint))
	}

	return snap, nil
}

func k8sPublicEndpointFromMap(ep map[string]interface{}) *edgev1.K8SPublicEndpointV1 {
	out := &edgev1.K8SPublicEndpointV1{
		ClusterId:             payloadString(ep, "cluster_id"),
		Ip:                    payloadString(ep, "ip"),
		Hostname:              payloadString(ep, "hostname"),
		Port:                  int32(payloadNumber(ep, "port")),
		Protocol:              payloadString(ep, "protocol"),
		ExposureClass:         payloadString(ep, "exposure_class"),
		ExternalTrafficPolicy: payloadString(ep, "external_traffic_policy"),
		MetallbPool:           payloadString(ep, "metallb_pool"),
		LoadBalancerIpMode:    payloadString(ep, "load_balancer_ip_mode"),
		Namespace:             payloadString(ep, "namespace"),
		ServiceName:           payloadString(ep, "service_name"),
		ServiceUid:            payloadString(ep, "service_uid"),
		GatewayName:           payloadString(ep, "gateway_name"),
		GatewayClass:          payloadString(ep, "gateway_class"),
		ListenerName:          payloadString(ep, "listener_name"),
		RouteKind:             payloadString(ep, "route_kind"),
		RouteName:             payloadString(ep, "route_name"),
		ServiceTargetPort:     int32(payloadNumber(ep, "service_target_port")),
		ServiceTargetName:     payloadString(ep, "service_target_name"),
		Annotations:           updateStringMap(ep["annotations"]),
		ObservedAt:            payloadString(ep, "observed_at"),
	}

	for _, rawRef := range payloadList(ep, "backend_refs") {
		ref, ok := rawRef.(map[string]interface{})
		if !ok || ref == nil {
			continue
		}
		out.BackendRefs = append(out.BackendRefs, &edgev1.K8SBackendRefV1{
			Group:     payloadString(ref, "group"),
			Kind:      payloadString(ref, "kind"),
			Namespace: payloadString(ref, "namespace"),
			Name:      payloadString(ref, "name"),
			Port:      int32(payloadNumber(ref, "port")),
			Weight:    int32(payloadNumber(ref, "weight")),
		})
	}

	for _, rawTarget := range payloadList(ep, "endpoint_targets") {
		target, ok := rawTarget.(map[string]interface{})
		if !ok || target == nil {
			continue
		}
		out.EndpointTargets = append(out.EndpointTargets, &edgev1.K8SEndpointTargetV1{
			Ip:           payloadString(target, "ip"),
			Port:         int32(payloadNumber(target, "port")),
			Protocol:     payloadString(target, "protocol"),
			PodNamespace: payloadString(target, "pod_namespace"),
			PodName:      payloadString(target, "pod_name"),
			NodeName:     payloadString(target, "node_name"),
			Ready:        payloadBool(target, "ready"),
		})
	}

	return out
}

func k8sCorrelationHintFromMap(hint map[string]interface{}) *edgev1.K8SCorrelationHintV1 {
	return &edgev1.K8SCorrelationHintV1{
		PublicIp:       payloadString(hint, "public_ip"),
		PublicHostname: payloadString(hint, "public_hostname"),
		PublicPort:     int32(payloadNumber(hint, "public_port")),
		Protocol:       payloadString(hint, "protocol"),
		BackendIp:      payloadString(hint, "backend_ip"),
		BackendPort:    int32(payloadNumber(hint, "backend_port")),
		PodNamespace:   payloadString(hint, "pod_namespace"),
		PodName:        payloadString(hint, "pod_name"),
		NodeName:       payloadString(hint, "node_name"),
		Namespace:      payloadString(hint, "namespace"),
		ServiceName:    payloadString(hint, "service_name"),
		GatewayName:    payloadString(hint, "gateway_name"),
		RouteKind:      payloadString(hint, "route_kind"),
		RouteName:      payloadString(hint, "route_name"),
		ExposureClass:  payloadString(hint, "exposure_class"),
	}
}
