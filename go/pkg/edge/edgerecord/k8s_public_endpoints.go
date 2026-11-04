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

package edgerecord

import (
	"fmt"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	K8sPublicEndpointsContractID                          = "serviceradar.k8s.public_endpoints.snapshot"
	K8sPublicEndpointsContractVersion              uint32 = 1
	K8sPublicEndpointsProjectedWriteBytesPerRecord uint64 = 8_192
)

// K8sPublicEndpointsSnapshotRows returns the projected row count for a
// Kubernetes public endpoints snapshot: the endpoint count when non-empty, or
// one for an empty-endpoints snapshot (which still soft-deletes missing
// cluster endpoints and updates k8s_public_endpoint_snapshots).
func K8sPublicEndpointsSnapshotRows(snap *edgev1.K8SPublicEndpointsSnapshotV1) int {
	return max(len(snap.GetEndpoints()), 1)
}

// ValidateK8sPublicEndpointsSnapshot enforces the snapshot payload rules: a
// non-empty cluster_id and every endpoint's cluster_id either empty or equal
// to the snapshot cluster_id.
func ValidateK8sPublicEndpointsSnapshot(snap *edgev1.K8SPublicEndpointsSnapshotV1) error {
	if snap == nil {
		return fmt.Errorf("%w: empty k8s public endpoints snapshot", ErrDiscoveryBatch)
	}
	clusterID := strings.TrimSpace(snap.GetClusterId())
	if clusterID == "" {
		return fmt.Errorf("%w: k8s public endpoints snapshot has no cluster id", ErrDiscoveryBatch)
	}
	for i, ep := range snap.GetEndpoints() {
		if ep == nil {
			return fmt.Errorf("%w: k8s public endpoint %d is nil", ErrDiscoveryBatch, i)
		}
		epCluster := strings.TrimSpace(ep.GetClusterId())
		if epCluster != "" && ep.GetClusterId() != snap.GetClusterId() {
			return fmt.Errorf(
				"%w: k8s public endpoint %d cluster_id %q does not match snapshot cluster_id %q",
				ErrDiscoveryBatch, i, ep.GetClusterId(), snap.GetClusterId(),
			)
		}
	}
	return nil
}

// ValidateK8sPublicEndpointsRecord is ValidateK8sPublicEndpointsSnapshot
// composed over a whole edge record.
func ValidateK8sPublicEndpointsRecord(r *edgev1.EdgeRecordV1) error {
	var snap edgev1.K8SPublicEndpointsSnapshotV1
	return validateDiscoveryRecord(r,
		contractRef{K8sPublicEndpointsContractID, K8sPublicEndpointsContractVersion}, &snap,
		func() (int, error) {
			return K8sPublicEndpointsSnapshotRows(&snap), ValidateK8sPublicEndpointsSnapshot(&snap)
		})
}
