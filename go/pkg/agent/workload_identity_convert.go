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
	"math"
	"strconv"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errWorkloadIdentityInvalidSnapshot = errors.New("invalid workload identity snapshot")

// parseWorkloadIdentitySnapshot converts a workload-identity JSON snapshot into
// its typed WorkloadIdentitySnapshotV1 message. Invalid lookup entries (non-object
// entries or entries without a container_id) are skipped and counted in dropped.
func parseWorkloadIdentitySnapshot(raw []byte) (snap *edgev1.WorkloadIdentitySnapshotV1, dropped int, err error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var payload map[string]interface{}
	if err := decoder.Decode(&payload); err != nil || len(payload) == 0 {
		return nil, 1, errWorkloadIdentityInvalidSnapshot
	}

	snap = &edgev1.WorkloadIdentitySnapshotV1{
		ObservedAtUnixNano: workloadIdentityObservedAtUnixNano(payload["observed_at_unix_nano"]),
		Enabled:            payloadBool(payload, "enabled"),
		Endpoint:           workloadIdentityEndpoint(payloadMap(payload, "endpoint")),
		Count:              uint32(max(payloadNumber(payload, "count"), 0)),
		DegradationReason:  payloadString(payload, "degradation_reason"),
		ContextName:        payloadString(payload, "context_name"),
		ClusterId:          payloadString(payload, "cluster_id"),
		ClusterName:        payloadString(payload, "cluster_name"),
	}

	rawIdentities, hasIdentities := payload["identities"]
	if !hasIdentities || rawIdentities == nil {
		return snap, 0, nil
	}

	slice, ok := rawIdentities.([]interface{})
	if !ok {
		return nil, 1, errWorkloadIdentityInvalidSnapshot
	}
	if len(slice) == 0 {
		return snap, 0, nil
	}

	identities := make([]*edgev1.WorkloadIdentityContainerLookupV1, 0, len(slice))
	for _, entry := range slice {
		entryMap, ok := entry.(map[string]interface{})
		if !ok {
			dropped++
			continue
		}
		lookup := workloadIdentityLookup(entryMap)
		if strings.TrimSpace(lookup.GetContainerId()) == "" &&
			strings.TrimSpace(lookup.GetIdentity().GetContainerId()) == "" {
			dropped++
			continue
		}
		identities = append(identities, lookup)
	}

	if len(identities) == 0 {
		return nil, dropped, errWorkloadIdentityInvalidSnapshot
	}

	snap.Identities = identities
	if dropped > 0 || snap.Count == 0 {
		snap.Count = uint32(len(identities))
	}
	return snap, dropped, nil
}

func workloadIdentityLookup(entry map[string]interface{}) *edgev1.WorkloadIdentityContainerLookupV1 {
	identityMap := payloadMap(entry, "identity")
	if identityMap == nil {
		identityMap = entry
	}

	lookupContainerID := payloadString(entry, "container_id")
	recordContainerID := payloadString(identityMap, "container_id")
	if lookupContainerID == "" && recordContainerID != "" {
		lookupContainerID = recordContainerID
	}
	if recordContainerID == "" && lookupContainerID != "" {
		recordContainerID = lookupContainerID
	}

	runtimePid, hasRuntimePid := optionalUint32Field(identityMap, "runtime_pid")

	return &edgev1.WorkloadIdentityContainerLookupV1{
		ContainerId: lookupContainerID,
		Identity: &edgev1.WorkloadIdentityRecordV1{
			PodSandboxId:      payloadString(identityMap, "pod_sandbox_id"),
			PodName:           payloadString(identityMap, "pod_name"),
			PodNamespace:      payloadString(identityMap, "pod_namespace"),
			PodUid:            payloadString(identityMap, "pod_uid"),
			ContainerId:       recordContainerID,
			ContainerName:     payloadString(identityMap, "container_name"),
			Image:             payloadString(identityMap, "image"),
			ImageRef:          payloadString(identityMap, "image_ref"),
			RuntimePid:        runtimePid,
			HasRuntimePid:     hasRuntimePid,
			CgroupPath:        payloadString(identityMap, "cgroup_path"),
			Labels:            updateStringMap(identityMap["labels"]),
			Annotations:       updateStringMap(identityMap["annotations"]),
			RuntimeSource:     workloadIdentityRuntimeSource(identityMap["runtime_source"]),
			Confidence:        payloadString(identityMap, "confidence"),
			DegradationReason: payloadString(identityMap, "degradation_reason"),
		},
	}
}

func workloadIdentityEndpoint(raw map[string]interface{}) *edgev1.WorkloadIdentitySnapshotEndpointV1 {
	if len(raw) == 0 {
		return nil
	}
	endpointType := payloadString(raw, "type")
	var path, source, configFilePath string
	if nested := payloadMap(raw, "endpoint"); nested != nil {
		path = payloadString(nested, "path")
		source, configFilePath = workloadIdentityEndpointSource(nested["source"], payloadString(nested, "config_file_path"))
	} else {
		path = payloadString(raw, "path")
		source, configFilePath = workloadIdentityEndpointSource(raw["source"], payloadString(raw, "config_file_path"))
	}
	if endpointType == "" && path == "" && source == "" && configFilePath == "" {
		return nil
	}
	return &edgev1.WorkloadIdentitySnapshotEndpointV1{
		Type:           endpointType,
		Path:           path,
		Source:         source,
		ConfigFilePath: configFilePath,
	}
}

func workloadIdentityEndpointSource(raw interface{}, fallbackConfigPath string) (string, string) {
	switch v := raw.(type) {
	case string:
		return v, fallbackConfigPath
	case map[string]interface{}:
		if cfgPath := payloadString(v, "ConfigFile"); cfgPath != "" {
			return "ConfigFile", cfgPath
		}
		for k, val := range v {
			if s, ok := val.(string); ok {
				return k, s
			}
			return k, fallbackConfigPath
		}
	}
	return "", fallbackConfigPath
}

func workloadIdentityRuntimeSource(raw interface{}) string {
	switch v := raw.(type) {
	case string:
		return v
	case map[string]interface{}:
		for k, val := range v {
			if s, ok := val.(string); ok && s != "" {
				return s
			}
			return k
		}
	}
	return ""
}

func workloadIdentityObservedAtUnixNano(raw interface{}) int64 {
	switch v := raw.(type) {
	case json.Number:
		if n, err := v.Int64(); err == nil {
			return n
		}
		if u, err := strconv.ParseUint(v.String(), 10, 64); err == nil && u <= math.MaxInt64 {
			return int64(u)
		}
	case float64:
		if v >= 0 && v <= math.MaxInt64 {
			return int64(v)
		}
	case int64:
		return v
	case int:
		return int64(v)
	}
	return 0
}

func optionalUint32Field(m map[string]interface{}, key string) (uint32, bool) {
	raw, ok := m[key]
	if !ok || raw == nil {
		return 0, false
	}
	switch v := raw.(type) {
	case json.Number:
		if n, err := v.Int64(); err == nil && n >= 0 && n <= math.MaxUint32 {
			return uint32(n), true
		}
	case float64:
		if v >= 0 && v <= math.MaxUint32 {
			return uint32(v), true
		}
	case int:
		if v >= 0 {
			return uint32(v), true
		}
	case uint32:
		return v, true
	}
	return 0, false
}
