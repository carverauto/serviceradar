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

package edgev1_test

import (
	"crypto/ed25519"
	"fmt"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// These are structural envelope fixtures, not body dispatch or deployment route tests.
// The recovery lane requires source authority even though ordinary lanes allow absence.
func TestFreezeRouteAndRegistryCoverage(t *testing.T) {
	var manifest strings.Builder
	for _, route := range []edgev1.EdgeRecordRouteProfile{1, 2, 3} {
		for _, source := range []bool{false, true} {
			r := canonicalRecord(t)
			r.RouteProfile = route
			r.OutputContract.RegistryEpoch = 1<<32 + uint64(route)
			if route == edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 {
				r.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
			}
			r.ProductionCapability = productionCap(r)
			if source {
				sa := r.SourceAuthorization
				sa.Capability = sourceCap(r, sa.ContextId, sa.ScopeId)
				if route == 3 {
					sa.Kind = edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL
					sa.Capability.GetSource().Kind = sa.Kind
					edgerecord.SignCapability(sa.Capability, issuerPrivB)
				}
			} else {
				r.SourceAuthorization = nil
			}
			r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
			name := fmt.Sprintf("freeze_route_%d_source_%t.bin", route, source)
			raw := golden(t, name, r)
			decoded, err := edgerecord.DecodeRecord(raw)
			if err != nil {
				t.Fatal(err)
			}
			accepted := route != 3 || source
			if err := edgerecord.ValidateRecord(decoded); (err == nil) != accepted {
				t.Fatalf("%s: accepted=%t, got %v", name, accepted, err)
			}
			if err := edgerecord.VerifyCapabilitySignature(decoded.ProductionCapability,
				edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION, issuerPrivA.Public().(ed25519.PublicKey)); err != nil {
				t.Fatal(err)
			}
			if source {
				if err := edgerecord.VerifyCapabilitySignature(decoded.SourceAuthorization.Capability,
					edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE, issuerPrivB.Public().(ed25519.PublicKey)); err != nil {
					t.Fatal(err)
				}
			}
			if decoded.OutputContract.RegistryEpoch != 1<<32+uint64(route) {
				t.Fatal("registry epoch truncated")
			}
			fmt.Fprintf(&manifest, "%s %d %t %d %t\n", name, route, source, r.OutputContract.RegistryEpoch, accepted)
		}
	}
	goldenBytes(t, "freeze_route_registry_corpus.txt", []byte(manifest.String()))
}
