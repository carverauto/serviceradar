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
	"fmt"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

func TestRecordStructuralBoundaryCorpus(t *testing.T) {
	var manifest strings.Builder
	emit := func(name string, accept bool, r *edgev1.EdgeRecordV1) {
		t.Helper()
		raw := golden(t, "record_boundary_"+name+".bin", r)
		decoded, err := edgerecord.DecodeRecord(raw)
		if err == nil {
			err = edgerecord.ValidateRecord(decoded)
		}
		if (err == nil) != accept {
			t.Fatalf("%s: accept=%v, got %v", name, accept, err)
		}
		fmt.Fprintf(&manifest, "record_boundary_%s.bin %t\n", name, accept)
	}
	control := canonicalRecord(t)
	emit("control", true, control)
	for _, tc := range []struct {
		name   string
		mutate func(*edgev1.EdgeRecordV1)
	}{
		{"event_id", func(r *edgev1.EdgeRecordV1) { r.EventId = nil }},
		{"payload_family", func(r *edgev1.EdgeRecordV1) { r.PayloadFamily = 0 }},
		{"route", func(r *edgev1.EdgeRecordV1) { r.RouteProfile = 0 }},
		{"traffic", func(r *edgev1.EdgeRecordV1) { r.TrafficClass = 0 }},
		{"encoded_size", func(r *edgev1.EdgeRecordV1) { r.EncodedSize++ }},
		{"uncompressed_size", func(r *edgev1.EdgeRecordV1) { r.UncompressedSize++ }},
		{"payload_digest", func(r *edgev1.EdgeRecordV1) { r.PayloadSha256 = digest32(0xff) }},
		{"contract_absent", func(r *edgev1.EdgeRecordV1) { r.OutputContract = nil }},
		{"contract_id", func(r *edgev1.EdgeRecordV1) { r.OutputContract.ContractId = "" }},
		{"contract_version", func(r *edgev1.EdgeRecordV1) { r.OutputContract.ContractVersion = 0 }},
		{"contract_bundle", func(r *edgev1.EdgeRecordV1) { r.OutputContract.ContractBundleSha256 = nil }},
		{"registry_epoch", func(r *edgev1.EdgeRecordV1) { r.OutputContract.RegistryEpoch = 0 }},
		{"registry_snapshot", func(r *edgev1.EdgeRecordV1) { r.OutputContract.RegistrySnapshotSha256 = nil }},
		{"effective_grant", func(r *edgev1.EdgeRecordV1) { r.OutputContract.EffectiveGrantSha256 = nil }},
		{"producer_absent", func(r *edgev1.EdgeRecordV1) { r.ProducerContext = nil }},
		{"origin", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.OriginKind = 0 }},
		{"instance", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.ProducerInstanceId = nil }},
		{"assignment", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.ProducerAssignmentId = nil }},
		{"run", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.RunId = nil }},
		{"scope", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.ScopeId = nil }},
		{"scope_digest", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.ScopeSha256 = nil }},
		{"authority_epoch", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.AuthorityEpoch = nil }},
		{"package_id", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.PackageId = "" }},
		{"package_digest", func(r *edgev1.EdgeRecordV1) { r.ProducerContext.PackageSha256 = nil }},
		{"network_scope", func(r *edgev1.EdgeRecordV1) { r.NetworkScopeId = nil }},
		{"production_absent", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability = nil }},
		{"capability_version", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability.CapabilityVersion = 0 }},
		{"issuer", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability.IssuerId = nil }},
		{"issuer_key", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability.IssuerKeyId = nil }},
		{"algorithm", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability.Algorithm = "unknown" }},
		{"capability_window", func(r *edgev1.EdgeRecordV1) {
			r.ProductionCapability.ExpiresAtUnixNano = r.ProductionCapability.NotBeforeUnixNano
		}},
		{"signature", func(r *edgev1.EdgeRecordV1) { r.ProductionCapability.Signature = nil }},
		{"source_capability", func(r *edgev1.EdgeRecordV1) { r.SourceAuthorization.Capability = nil }},
		{"recovery_route", func(r *edgev1.EdgeRecordV1) {
			r.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
			r.ProductionCapability.GetProduction().RouteProfile = r.RouteProfile
			r.SourceAuthorization.Capability.GetSource().RouteProfile = r.RouteProfile
		}},
		{"event_time_before", func(r *edgev1.EdgeRecordV1) { r.EventId = uuidv7At(fixedMillis - 7_200_000) }},
		{"event_time_after", func(r *edgev1.EdgeRecordV1) { r.EventId = uuidv7At(fixedMillis + 7_200_000) }},
		{"event_time_overflow", func(r *edgev1.EdgeRecordV1) { r.EventId = uuidv7At(20_230_744_073_710) }},
	} {
		r := proto.Clone(control).(*edgev1.EdgeRecordV1)
		tc.mutate(r)
		r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
		emit(tc.name, false, r)
	}
	for _, n := range []int{0, 1, 128, 129} {
		r := proto.Clone(control).(*edgev1.EdgeRecordV1)
		principal := []byte(strings.Repeat("a", n))
		r.ProducerContext.OriginPrincipalId = principal
		r.ProductionCapability.GetProduction().OriginPrincipalId = principal
		r.SourceAuthorization.Capability.GetSource().OriginPrincipalId = principal
		r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
		emit(fmt.Sprintf("principal_%d", n), n == 1 || n == 128, r)
	}
	recordBoundaryClaimCases(control, emit)
	recordBoundaryTimeCases(control, emit)
	// A stale digest must be refused independently of all identity/grant checks.
	r := proto.Clone(control).(*edgev1.EdgeRecordV1)
	r.SemanticEnvelopeSha256 = digest32(0xff)
	emit("semantic_digest", false, r)
	r = proto.Clone(control).(*edgev1.EdgeRecordV1)
	r.SourceAuthorization = nil
	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
	emit("source_absent", true, r)
	goldenText(t, "record_boundary_corpus.txt", manifest.String())
}

func recordBoundaryClaimCases(control *edgev1.EdgeRecordV1, emit func(string, bool, *edgev1.EdgeRecordV1)) {
	for _, role := range []string{"production", "source"} {
		var claims proto.Message = control.ProductionCapability.GetProduction()
		if role == "source" {
			claims = control.SourceAuthorization.Capability.GetSource()
		}
		fields := claims.ProtoReflect().Descriptor().Fields()
		for i := 0; i < fields.Len(); i++ {
			f := fields.Get(i)
			name := string(f.Name())
			// Plan/range joins belong to the typed payload boundary; collection
			// time has its own signed-window vectors below.
			if role == "source" && (name == "execution_plan_sha256" || name == "target_range_sha256" || strings.HasPrefix(name, "collection_")) {
				continue
			}
			r := proto.Clone(control).(*edgev1.EdgeRecordV1)
			var changed proto.Message = r.ProductionCapability.GetProduction()
			if role == "source" {
				changed = r.SourceAuthorization.Capability.GetSource()
			}
			m := changed.ProtoReflect()
			switch f.Kind() {
			case protoreflect.BytesKind:
				b := append([]byte(nil), m.Get(f).Bytes()...)
				b[0] ^= 0xff
				m.Set(f, protoreflect.ValueOfBytes(b))
			case protoreflect.StringKind:
				m.Set(f, protoreflect.ValueOfString(m.Get(f).String()+"x"))
			case protoreflect.EnumKind:
				other := protoreflect.EnumNumber(1)
				if m.Get(f).Enum() == other {
					other = 2
				}
				m.Set(f, protoreflect.ValueOfEnum(other))
			default:
				value := m.Get(f).Uint() + 1
				if strings.HasPrefix(name, "max_projected_") {
					value = m.Get(f).Uint() - 1
				}
				m.Set(f, protoreflect.ValueOfUint64(value))
			}
			r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
			emit(role+"_"+name, false, r)
		}
	}
}

func recordBoundaryTimeCases(control *edgev1.EdgeRecordV1, emit func(string, bool, *edgev1.EdgeRecordV1)) {
	// Each signed time window is independently necessary. Equality at either
	// endpoint is legal, and a one-nanosecond exclusion must refuse.
	for _, window := range []string{"production", "source", "collection"} {
		for _, side := range []string{"first", "last"} {
			for _, accepted := range []bool{true, false} {
				r := proto.Clone(control).(*edgev1.EdgeRecordV1)
				value := fixedNanos
				if !accepted {
					if side == "first" {
						value++
					} else {
						value--
					}
				}
				cap := r.ProductionCapability
				if window == "source" {
					cap = r.SourceAuthorization.Capability
				}
				if window == "collection" {
					claims := r.SourceAuthorization.Capability.GetSource()
					if side == "first" {
						claims.CollectionNotBeforeUnixNano = value
					} else {
						claims.CollectionExpiresUnixNano = value
					}
				} else if side == "first" {
					cap.NotBeforeUnixNano = value
				} else {
					cap.ExpiresAtUnixNano = value
				}
				r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
				emit(fmt.Sprintf("time_%s_%s_%t", window, side, accepted), accepted, r)
			}
		}
	}
}
