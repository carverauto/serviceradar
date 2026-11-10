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
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func bindingFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "proto", "edge", "v1", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func bindingHex(t *testing.T, m map[string]any, key string) []byte {
	t.Helper()
	b, err := hex.DecodeString(m[key].(string))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func bindingCorpusInput(t *testing.T, v map[string]any) (LocalBindingCoordinates, RecoveryAttribution) {
	t.Helper()
	c := v["coordinates"].(map[string]any)
	a := v["attribution"].(map[string]any)
	i := a["identity"].(map[string]any)
	id := &edgev1.EdgeAttributedSpanIdentityV1{
		ContractBundleSha256: bindingHex(t, i, "contract_bundle_sha256"),
		ProducerAssignmentId: bindingHex(t, i, "producer_assignment_id"), RunId: bindingHex(t, i, "run_id"),
		RunShard: uint32(i["run_shard"].(float64)), AuthorityEpoch: uint64(i["authority_epoch"].(float64)),
		ProductionScopeId: bindingHex(t, i, "production_scope_id"), ScopeSha256: bindingHex(t, i, "scope_sha256"),
	}
	if s, ok := i["source"].(map[string]any); ok {
		id.Source = &edgev1.EdgeSourceSpanIdentityV1{
			Kind: edgev1.EdgeSourceAuthorizationKind(s["kind"].(float64)), ContextId: bindingHex(t, s, "context_id"),
			SourceScopeId: bindingHex(t, s, "source_scope_id"), SourceScopeSha256: bindingHex(t, s, "source_scope_sha256"),
		}
	}
	return LocalBindingCoordinates{
		NetworkScopeID: bindingHex(t, c, "network_scope_id"), AuthenticatedAgentID: []byte(c["authenticated_agent_id"].(string)),
		LaneRouteProfile:  edgev1.EdgeRecordRouteProfile(c["lane_route_profile"].(float64)),
		LaneTrafficClass:  edgev1.EdgeRecordTrafficClass(c["lane_traffic_class"].(float64)),
		SpoolGenerationID: bindingHex(t, c, "spool_generation_id"), Sequence: uint64(c["sequence"].(float64)),
		EventID: bindingHex(t, c, "event_id"), RecordSHA256: bindingHex(t, c, "record_sha256"),
	}, RecoveryAttribution{Active: a["active"].(bool), Identity: id, RangeSHA256: bindingHex(t, a, "range_sha256")}
}

func TestLocalBindingSharedCorpus(t *testing.T) {
	var corpus struct {
		Vectors []map[string]any `json:"vectors"`
	}
	if err := json.Unmarshal(bindingFixture(t, "local_binding_corpus.json"), &corpus); err != nil {
		t.Fatal(err)
	}
	if len(corpus.Vectors) == 0 {
		t.Fatal("empty binding corpus")
	}
	for _, v := range corpus.Vectors {
		t.Run(v["name"].(string), func(t *testing.T) {
			c, a := bindingCorpusInput(t, v)
			digest, err := LocalBindingDigest(uint64(v["version"].(float64)), c, a)
			if want, ok := v["error"].(string); ok {
				expected := ErrLocalBinding
				if want == "local_binding_version" {
					expected = ErrLocalBindingVersion
				}
				if !errors.Is(err, expected) || digest != nil {
					t.Fatalf("got (%x,%v), want %v", digest, err, expected)
				}
			} else if err != nil || hex.EncodeToString(digest) != v["digest"] {
				t.Fatalf("digest = %x, %v; want %s", digest, err, v["digest"])
			}
		})
	}
	// An unsupported readable version wins over an otherwise unreadable body.
	if _, err := LocalBindingDigest(2, LocalBindingCoordinates{}, RecoveryAttribution{}); !errors.Is(err, ErrLocalBindingVersion) {
		t.Fatal(err)
	}
}

func signBindingRecord(t *testing.T, r *edgev1.EdgeRecordV1) ([]byte, AuthorizationPolicy) {
	t.Helper()
	priv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x39}, ed25519.SeedSize))
	pub := priv.Public().(ed25519.PublicKey)
	SignCapability(r.ProductionCapability, priv)
	trust := mapTrust{trustKey(r.ProductionCapability.IssuerId, r.ProductionCapability.IssuerKeyId): pub}
	if s := r.SourceAuthorization; s != nil {
		SignCapability(s.Capability, priv)
		trust[trustKey(s.Capability.IssuerId, s.Capability.IssuerKeyId)] = pub
	}
	reseal(r)
	raw, err := CanonicalRecordBytes(r)
	if err != nil {
		t.Fatal(err)
	}
	return raw, AuthorizationPolicy{Trust: trust, TrustPolicyEpoch: 1, NowUnixNano: nowFor(t, r.EventId), ActiveFence: ResolvedFence(r.ProducerContext.GetAuthorityEpoch())}
}

func bindingCoordinates(r *edgev1.EdgeRecordV1, raw []byte) LocalBindingCoordinates {
	hash := sha256.Sum256(raw)
	return LocalBindingCoordinates{
		NetworkScopeID: bytes.Clone(r.NetworkScopeId), AuthenticatedAgentID: bytes.Clone(r.ProducerContext.OriginPrincipalId),
		LaneRouteProfile: r.RouteProfile, LaneTrafficClass: r.TrafficClass, SpoolGenerationID: fixedUUIDv7(0x31), Sequence: 9,
		EventID: bytes.Clone(r.EventId), RecordSHA256: hash[:],
	}
}

func TestValidatedAttributionJoinsBeforeBinding(t *testing.T) {
	const sweep, control, metrics = "sweep", "control", "metrics"
	for _, contract := range []string{sweep, control, metrics} {
		t.Run(contract, func(t *testing.T) {
			var r *edgev1.EdgeRecordV1
			var err error
			if contract == metrics {
				r = metricBatchRecord(t, 1, 1)
			} else {
				name := "sweep_join_positive_scheduled_sweep.bin"
				if contract == control {
					name = "version_tombstone_scope_ok.bin"
				}
				r, err = DecodeRecord(bindingFixture(t, name))
				if err != nil {
					t.Fatal(err)
				}
			}
			raw, policy := signBindingRecord(t, r)
			var validated ValidatedAttribution
			switch contract {
			case sweep:
				validated, err = SweepRecoveryAttribution(raw, r.OutputContract, policy)
			case control:
				validated, err = ControlRecoveryAttribution(raw, r.OutputContract, policy)
			case metrics:
				validated, err = MetricRecoveryAttribution(raw, policy)
			}
			if err != nil {
				t.Fatal(err)
			}
			a := validated.Attribution()
			if a.Active != (contract == sweep) || (a.Identity.Source != nil) != (contract != metrics) {
				t.Fatalf("wrong classification: %+v", a)
			}
			c := bindingCoordinates(r, raw)
			original, err := validated.Bind(c, a)
			if err != nil {
				t.Fatal(err)
			}
			mutations := map[string]func(*RecoveryAttribution){
				"production_scope_id_same_digest": func(a *RecoveryAttribution) { a.Identity.ProductionScopeId = fixedUUIDv7(0x41) },
				"production_scope_digest":         func(a *RecoveryAttribution) { a.Identity.ScopeSha256 = d32(0x42) },
				"contract_bundle":                 func(a *RecoveryAttribution) { a.Identity.ContractBundleSha256 = d32(0x43) },
				"assignment":                      func(a *RecoveryAttribution) { a.Identity.ProducerAssignmentId = fixedUUIDv7(0x44) },
				"run":                             func(a *RecoveryAttribution) { a.Identity.RunId = fixedUUIDv7(0x45) },
				"shard":                           func(a *RecoveryAttribution) { a.Identity.RunShard++ },
				"epoch":                           func(a *RecoveryAttribution) { a.Identity.AuthorityEpoch++ },
				"classification":                  func(a *RecoveryAttribution) { a.Active = !a.Active },
			}
			if a.Active {
				mutations["range"] = func(a *RecoveryAttribution) { a.RangeSHA256 = d32(0x46) }
			}
			if a.Identity.Source != nil {
				mutations["source_scope_id_same_digest"] = func(a *RecoveryAttribution) { a.Identity.Source.SourceScopeId = fixedUUIDv7(0x47) }
				mutations["source_kind_same_context"] = func(a *RecoveryAttribution) {
					a.Identity.Source.Kind = edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC
				}
				mutations["source_context"] = func(a *RecoveryAttribution) { a.Identity.Source.ContextId = fixedUUIDv7(0x48) }
				mutations["source_digest"] = func(a *RecoveryAttribution) { a.Identity.Source.SourceScopeSha256 = d32(0x49) }
				mutations["source_absent"] = func(a *RecoveryAttribution) { a.Identity.Source = nil }
			} else {
				mutations["source_present"] = func(a *RecoveryAttribution) {
					a.Identity.Source = &edgev1.EdgeSourceSpanIdentityV1{
						Kind:      edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
						ContextId: fixedUUIDv7(0x48), SourceScopeId: fixedUUIDv7(0x47), SourceScopeSha256: d32(0x49),
					}
				}
			}
			for name, mutate := range mutations {
				t.Run(name, func(t *testing.T) {
					changed := validated.Attribution()
					mutate(&changed)
					if _, err := validated.Bind(c, changed); !errors.Is(err, ErrAttributionJoin) {
						t.Fatalf("got %v", err)
					}
				})
			}
			for name, mutate := range map[string]func(*LocalBindingCoordinates){
				"network_scope": func(c *LocalBindingCoordinates) { c.NetworkScopeID = fixedUUIDv7(0x51) },
				"agent":         func(c *LocalBindingCoordinates) { c.AuthenticatedAgentID = []byte("other_synthetic_agent") },
				"event":         func(c *LocalBindingCoordinates) { c.EventID = fixedUUIDv7(0x52) },
				"record_bytes":  func(c *LocalBindingCoordinates) { c.RecordSHA256 = d32(0x53) },
				"route": func(c *LocalBindingCoordinates) {
					c.LaneRouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED
				},
				"traffic_class": func(c *LocalBindingCoordinates) {
					c.LaneTrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
				},
			} {
				t.Run(name, func(t *testing.T) {
					changed := c
					mutate(&changed)
					if _, err := validated.Bind(changed, validated.Attribution()); !errors.Is(err, ErrAttributionJoin) {
						t.Fatalf("coordinate substitution: %v", err)
					}
				})
			}
			// Accessor mutation cannot mutate the sealed proof.
			a.Identity.ProductionScopeId[0] ^= 1
			if got, err := validated.Bind(c, validated.Attribution()); err != nil || !bytes.Equal(got, original) {
				t.Fatalf("proof mutated: %x %v", got, err)
			}
			c.SpoolGenerationID = fixedUUIDv7(0x32)
			if rebound, err := validated.Bind(c, validated.Attribution()); err != nil || bytes.Equal(rebound, original) {
				t.Fatalf("rebind: %x %v", rebound, err)
			}
			if _, err := (ValidatedAttribution{}).Bind(c, validated.Attribution()); !errors.Is(err, ErrAttributionJoin) {
				t.Fatalf("zero proof: %v", err)
			}
		})
	}
}

func TestAttributionConstructorChecksBodyCorrelation(t *testing.T) {
	r, err := DecodeRecord(bindingFixture(t, "sweep_join_range_id.bin"))
	if err != nil {
		t.Fatal(err)
	}
	raw, policy := signBindingRecord(t, r)
	if _, err := SweepRecoveryAttribution(raw, r.OutputContract, policy); !errors.Is(err, ErrSweepJoin) {
		t.Fatalf("body scope substitution: %v", err)
	}
}

func TestRegisteredAttributionUsesContractAuthorityAndBodyValidator(t *testing.T) {
	sweep, err := DecodeRecord(bindingFixture(t, "sweep_join_positive_scheduled_sweep.bin"))
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range []*edgev1.EdgeRecordV1{sweep, metricBatchRecord(t, 1, 1), scheduledMtrRecord(t, scheduledMtrBatch(t), 1)} {
		t.Run(r.OutputContract.ContractId, func(t *testing.T) {
			raw, policy := signBindingRecord(t, r)
			validated, err := RecordRecoveryAttribution(raw, r.OutputContract, policy)
			if err != nil {
				t.Fatal(err)
			}
			a := validated.Attribution()
			active := r.OutputContract.ContractId == SweepObservationContractID
			if a.Active != active || (!active && (a.Identity.Source != nil || len(a.RangeSHA256) != 0)) {
				t.Fatalf("contract authority changed: %+v", a)
			}
			if _, err = validated.Bind(bindingCoordinates(r, raw), a); err != nil {
				t.Fatal(err)
			}
			wrong := proto.Clone(r.OutputContract).(*edgev1.EdgeOutputContractRef)
			wrong.ContractBundleSha256 = d32(0x76)
			if _, err = RecordRecoveryAttribution(raw, wrong, policy); !errors.Is(err, ErrContractDispatch) {
				t.Fatalf("wrong registered bundle accepted: %v", err)
			}
			broken := proto.Clone(r).(*edgev1.EdgeRecordV1)
			broken.Payload = []byte{0xff}
			hash := sha256.Sum256(broken.Payload)
			broken.PayloadSha256 = hash[:]
			broken.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE
			broken.EncodedSize, broken.UncompressedSize = 1, 1
			badRaw, badPolicy := signBindingRecord(t, broken)
			if _, err = RecordRecoveryAttribution(badRaw, broken.OutputContract, badPolicy); err == nil {
				t.Fatal("signed malformed typed body minted attribution")
			}
		})
	}
	for _, version := range []uint32{1, 2} {
		r := metricBatchRecord(t, 1, 1)
		if version == 1 {
			r.OutputContract.ContractId = "synthetic.unknown.contract"
		}
		r.OutputContract.ContractVersion = version
		r.ProductionCapability.GetProduction().ContractId = r.OutputContract.ContractId
		r.ProductionCapability.GetProduction().ContractVersion = version
		raw, policy := signBindingRecord(t, r)
		if _, err := RecordRecoveryAttribution(raw, r.OutputContract, policy); !errors.Is(err, ErrContractDispatch) {
			t.Fatalf("unknown contract/version accepted: %v", err)
		}
	}
}
