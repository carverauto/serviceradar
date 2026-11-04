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
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestValidateK8sPublicEndpointsRecord(t *testing.T) {
	t.Parallel()

	t.Run("accepts populated snapshot and empty-endpoints snapshot", func(t *testing.T) {
		t.Parallel()
		populated := &edgev1.K8SPublicEndpointsSnapshotV1{
			SchemaVersion: "serviceradar.k8s_public_endpoints.v1",
			AgentId:       "agent-k8s-1",
			ClusterId:     "cluster-alpha",
			GeneratedAt:   "2026-07-01T12:00:00Z",
			Endpoints: []*edgev1.K8SPublicEndpointV1{
				{
					ClusterId:   "cluster-alpha",
					Ip:          "192.0.2.10",
					Port:        443,
					Protocol:    "TCP",
					Namespace:   "default",
					ServiceName: "web-ingress",
				},
				{
					Ip:          "192.0.2.11",
					Port:        8443,
					Protocol:    "TCP",
					Namespace:   "default",
					ServiceName: "api-ingress",
				},
			},
		}
		ref := contractRef{K8sPublicEndpointsContractID, K8sPublicEndpointsContractVersion}
		r := discoveryRecord(t, ref, K8sPublicEndpointsProjectedWriteBytesPerRecord, populated, 2)
		if err := ValidateK8sPublicEndpointsRecord(r); err != nil {
			t.Fatalf("unexpected error for populated snapshot: %v", err)
		}

		empty := &edgev1.K8SPublicEndpointsSnapshotV1{
			SchemaVersion: "serviceradar.k8s_public_endpoints.v1",
			AgentId:       "agent-k8s-1",
			ClusterId:     "cluster-alpha",
			GeneratedAt:   "2026-07-01T12:05:00Z",
		}
		rEmpty := discoveryRecord(t, ref, K8sPublicEndpointsProjectedWriteBytesPerRecord, empty, 1)
		if err := ValidateK8sPublicEndpointsRecord(rEmpty); err != nil {
			t.Fatalf("unexpected error for empty-endpoints snapshot: %v", err)
		}
	})

	t.Run("rejects missing cluster_id, mismatched endpoint cluster_id, and wrong row count", func(t *testing.T) {
		t.Parallel()
		ref := contractRef{K8sPublicEndpointsContractID, K8sPublicEndpointsContractVersion}
		noCluster := &edgev1.K8SPublicEndpointsSnapshotV1{
			AgentId: "agent-k8s-1",
		}
		r := discoveryRecord(t, ref, K8sPublicEndpointsProjectedWriteBytesPerRecord, noCluster, 1)
		if err := ValidateK8sPublicEndpointsRecord(r); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("expected ErrDiscoveryBatch for missing cluster_id, got %v", err)
		}

		mismatch := &edgev1.K8SPublicEndpointsSnapshotV1{
			ClusterId: "cluster-alpha",
			Endpoints: []*edgev1.K8SPublicEndpointV1{
				{ClusterId: "cluster-beta", Ip: "192.0.2.10", Port: 443},
			},
		}
		r = discoveryRecord(t, ref, K8sPublicEndpointsProjectedWriteBytesPerRecord, mismatch, 1)
		if err := ValidateK8sPublicEndpointsRecord(r); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("expected ErrDiscoveryBatch for mismatched endpoint cluster_id, got %v", err)
		}

		validSnap := &edgev1.K8SPublicEndpointsSnapshotV1{
			ClusterId: "cluster-alpha",
			Endpoints: []*edgev1.K8SPublicEndpointV1{
				{Ip: "192.0.2.10", Port: 443},
				{Ip: "192.0.2.11", Port: 8443},
			},
		}
		rWrongRows := discoveryRecord(t, ref, K8sPublicEndpointsProjectedWriteBytesPerRecord, validSnap, 1)
		if err := ValidateK8sPublicEndpointsRecord(rWrongRows); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("expected ErrDiscoveryBatch for wrong projected_row_count, got %v", err)
		}
	})
}
