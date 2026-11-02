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
	"crypto/sha256"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// newEdgeRecord assembles one RECORD_BATCH_V1 edge record carrying payload (the
// deterministic encoding of a typed batch) under capability. Every contract and
// producer field is copied from the capability's production claims, so a record
// can only name the authority core signed. source is nil for a contract that runs
// under a standing grant. The caller validates the record with its contract's
// composed validator before spooling it.
func newEdgeRecord(
	capability *edgev1.EdgeSignedCapabilityV1,
	source *edgev1.EdgeSourceAuthorizationV1,
	payload []byte,
	rows uint32,
	writeBytes uint64,
) (*edgev1.EdgeRecordV1, error) {
	eventID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, err
	}
	compression, encoded, err := edgerecord.EncodeRecordPayload(payload)
	if err != nil {
		return nil, err
	}
	c := capability.GetProduction()
	sum := sha256.Sum256(encoded)
	record := &edgev1.EdgeRecordV1{
		EventId:          eventID,
		PayloadFamily:    edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		Compression:      compression,
		EncodedSize:      uint32(len(encoded)),
		UncompressedSize: uint32(len(payload)),
		PayloadSha256:    sum[:],
		Payload:          encoded,
		OutputContract: &edgev1.EdgeOutputContractRef{
			ContractId: c.GetContractId(), ContractVersion: c.GetContractVersion(),
			ContractBundleSha256: c.GetContractBundleSha256(), RegistryEpoch: c.GetRegistryEpoch(),
			RegistrySnapshotSha256: c.GetRegistrySnapshotSha256(), EffectiveGrantSha256: c.GetEffectiveGrantSha256(),
		},
		ProducerContext: &edgev1.EdgeProducerContext{
			OriginKind: c.GetOriginKind(), OriginPrincipalId: c.GetOriginPrincipalId(),
			ProducerInstanceId: c.GetProducerInstanceId(), ProducerAssignmentId: c.GetProducerAssignmentId(),
			RunId: c.GetRunId(), RunShard: c.GetRunShard(), AuthorityEpoch: proto.Uint64(c.GetAuthorityEpoch()),
			ScopeId: c.GetScopeId(), ScopeSha256: c.GetScopeSha256(),
			PackageId: c.GetPackageId(), PackageSha256: c.GetPackageSha256(),
		},
		RouteProfile:         c.GetRouteProfile(),
		TrafficClass:         c.GetTrafficClass(),
		NetworkScopeId:       c.GetNetworkScopeId(),
		ProductionCapability: capability,
		SourceAuthorization:  source,
		ProjectedRowCount:    rows,
		ProjectedWriteBytes:  writeBytes,
		CostModelVersion:     c.GetCostModelVersion(),
	}
	record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(record)
	return record, nil
}
