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
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// M2.0i1: the plan-carried check-set corpus, the decoding half. Elixir encodes
// every sweep_lease_check_sets_*.bin from core's own plan builder and check-set
// grammar (elixir/serviceradar_core/test/serviceradar/edge/
// sweep_lease_check_sets_corpus_test.exs); this side decodes the same bytes and
// requires each fixture's carrier and run-shape verdict.

func loadSweepLeaseCheckSetsFixture(t *testing.T, name string) *edgev1.SweepLeaseV1 {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "proto", "edge", "v1", "testdata", name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	lease := &edgev1.SweepLeaseV1{}
	if err := proto.Unmarshal(raw, lease); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	return lease
}

func TestSweepLeaseCheckSetsCorpusAccept(t *testing.T) {
	lease := loadSweepLeaseCheckSetsFixture(t, "sweep_lease_check_sets_accept.bin")

	sets, err := SweepLeaseCheckSets(lease)
	if err != nil {
		t.Fatalf("accept fixture refused: %v", err)
	}
	if len(sets) != 2 || len(lease.GetSlots()) != 3 {
		t.Fatalf("got %d carried sets for %d slots, want 2 for 3", len(sets), len(lease.GetSlots()))
	}

	want := map[string]SweepCheckSetRunSpec{
		"icmp+tcp_syn": {
			Modes: []edgev1.SweepMode{edgev1.SweepMode_SWEEP_MODE_ICMP, edgev1.SweepMode_SWEEP_MODE_TCP_SYN},
			Ports: []uint32{22, 443},
		},
		"icmp": {Modes: []edgev1.SweepMode{edgev1.SweepMode_SWEEP_MODE_ICMP}},
	}
	for i, slot := range lease.GetSlots() {
		header := slot.GetPlanHeader()
		if err := ValidatePlanHeader(header); err != nil {
			t.Fatalf("slot %d plan header: %v", i, err)
		}
		if err := ValidatePlanPages(header, slot.GetPlanPages()); err != nil {
			t.Fatalf("slot %d plan pages: %v", i, err)
		}

		spec, err := SweepCheckSetRun(sets[string(header.GetCheckSetSha256())])
		if err != nil {
			t.Fatalf("slot %d run shape: %v", i, err)
		}
		name := "icmp"
		if i < 2 {
			name = "icmp+tcp_syn"
		}
		if !slices.Equal(spec.Modes, want[name].Modes) || !slices.Equal(spec.Ports, want[name].Ports) {
			t.Fatalf("slot %d runs %+v, want %+v", i, spec, want[name])
		}
	}
}

func TestSweepLeaseCheckSetsCorpusRefusals(t *testing.T) {
	// reason pins which rule refused the fixture, so a fixture refused by an
	// unrelated rule fails instead of passing.
	for _, tc := range []struct {
		file     string
		pushErr  error
		slotsErr error
		reason   string
	}{
		{file: "sweep_lease_check_sets_digest_mismatch.bin", pushErr: ErrSweepLeaseCheckSets, reason: "does not digest to its key"},
		{file: "sweep_lease_check_sets_unresolved.bin", pushErr: ErrSweepLeaseCheckSets, reason: "is not carried"},
		{file: "sweep_lease_check_sets_unreferenced.bin", pushErr: ErrSweepLeaseCheckSets, reason: "referenced by no slot"},
		{file: "sweep_lease_check_sets_version_1.bin", pushErr: ErrSweepLeaseCheckSets, reason: "lease_version 1 carries slots"},
		{file: "sweep_lease_check_sets_not_product.bin", slotsErr: ErrSweepCheckSetUnsupported, reason: "TCP modes probe different ports"},
		{file: "sweep_lease_check_sets_unknown_digest_version.bin", slotsErr: ErrSweepCheckSetUnsupported, reason: "digest_version 2"},
	} {
		t.Run(tc.file, func(t *testing.T) {
			lease := loadSweepLeaseCheckSetsFixture(t, tc.file)

			sets, err := SweepLeaseCheckSets(lease)
			if tc.pushErr != nil {
				if !errors.Is(err, tc.pushErr) || !strings.Contains(err.Error(), tc.reason) {
					t.Fatalf("push verdict %v, want %v: %s", err, tc.pushErr, tc.reason)
				}
				return
			}
			if err != nil {
				t.Fatalf("push refused, want a slot refusal: %v", err)
			}
			for i, slot := range lease.GetSlots() {
				_, err := SweepCheckSetRun(sets[string(slot.GetPlanHeader().GetCheckSetSha256())])
				if !errors.Is(err, tc.slotsErr) || !strings.Contains(err.Error(), tc.reason) {
					t.Fatalf("slot %d verdict %v, want %v: %s", i, err, tc.slotsErr, tc.reason)
				}
			}
		})
	}
}

// SweepCheckSetRun refuses modes the edge scanner does not execute. UNSPECIFIED
// and MTR are real enum values; a value outside the enum takes the same refusal.
// ICMP and the two TCP modes still become a run shape, so a blanket refusal
// fails this test too.
func TestSweepCheckSetRunRefusesModesTheScannerDoesNotProduce(t *testing.T) {
	for _, mode := range []edgev1.SweepMode{
		edgev1.SweepMode_SWEEP_MODE_UNSPECIFIED,
		edgev1.SweepMode_SWEEP_MODE_MTR,
		edgev1.SweepMode(99),
	} {
		t.Run(mode.String(), func(t *testing.T) {
			_, err := SweepCheckSetRun(&edgev1.SweepCheckSetV1{
				DigestVersion: CheckSetDigestVersion,
				Checks: []*edgev1.SweepTestV1{{
					Mode:     mode,
					Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
					Port:     0,
				}},
			})
			if !errors.Is(err, ErrSweepCheckSetUnsupported) {
				t.Fatalf("%s: %v, want %v", mode, err, ErrSweepCheckSetUnsupported)
			}
		})
	}

	icmp, err := SweepCheckSetRun(&edgev1.SweepCheckSetV1{
		DigestVersion: CheckSetDigestVersion,
		Checks: []*edgev1.SweepTestV1{{
			Mode:     edgev1.SweepMode_SWEEP_MODE_ICMP,
			Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
		}},
	})
	if err != nil {
		t.Fatalf("ICMP: %v", err)
	}
	if !slices.Equal(icmp.Modes, []edgev1.SweepMode{edgev1.SweepMode_SWEEP_MODE_ICMP}) || len(icmp.Ports) != 0 {
		t.Fatalf("ICMP runs %+v, want ICMP and no ports", icmp)
	}

	tcp, err := SweepCheckSetRun(&edgev1.SweepCheckSetV1{
		DigestVersion: CheckSetDigestVersion,
		Checks: []*edgev1.SweepTestV1{
			{
				Mode:     edgev1.SweepMode_SWEEP_MODE_TCP_SYN,
				Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
				Port:     22,
			},
			{
				Mode:     edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT,
				Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
				Port:     22,
			},
		},
	})
	if err != nil {
		t.Fatalf("TCP: %v", err)
	}
	if !slices.Equal(tcp.Modes, []edgev1.SweepMode{
		edgev1.SweepMode_SWEEP_MODE_TCP_SYN,
		edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT,
	}) || !slices.Equal(tcp.Ports, []uint32{22}) {
		t.Fatalf("TCP runs %+v, want TCP_SYN and TCP_CONNECT on port 22", tcp)
	}
}

// A push without slots carries nothing version-dependent: a revocation stays
// lease_version 1 and is accepted, while check sets on it are unreferenced.
func TestSweepLeaseCheckSetsWithoutSlots(t *testing.T) {
	revocation := &edgev1.SweepLeaseV1{LeaseVersion: 1, Revoked: true}
	if _, err := SweepLeaseCheckSets(revocation); err != nil {
		t.Fatalf("revocation refused: %v", err)
	}

	revocation.CheckSets = []*edgev1.SweepCheckSetV1{{CheckSetSha256: make([]byte, 32), DigestVersion: 1}}
	if _, err := SweepLeaseCheckSets(revocation); !errors.Is(err, ErrSweepLeaseCheckSets) {
		t.Fatalf("check sets on a slotless push: %v, want %v", err, ErrSweepLeaseCheckSets)
	}
}

// The canonical order is part of the digest grammar: a set whose checks digest
// to its key in a non-canonical order is still refused, because core never
// emits it and an agent would otherwise index the same checks two ways.
func TestSweepLeaseCheckSetsRefusesNonCanonicalOrder(t *testing.T) {
	lease := loadSweepLeaseCheckSetsFixture(t, "sweep_lease_check_sets_accept.bin")
	set := lease.GetCheckSets()[0]
	checks := set.GetChecks()
	checks[1], checks[2] = checks[2], checks[1]
	set.CheckSetSha256 = CheckSetDigest(checks)
	for _, slot := range lease.GetSlots()[:2] {
		slot.GetPlanHeader().CheckSetSha256 = set.GetCheckSetSha256()
	}

	if _, err := SweepLeaseCheckSets(lease); !errors.Is(err, ErrSweepLeaseCheckSets) {
		t.Fatalf("non-canonical set: %v, want %v", err, ErrSweepLeaseCheckSets)
	}
}
