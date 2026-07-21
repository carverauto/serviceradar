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

package targetplan

import (
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func makePage(t *testing.T, planID []byte, index uint32, cidrs ...string) *edgev1.ScheduledPlanPageV1 {
	t.Helper()
	page := &edgev1.ScheduledPlanPageV1{ExecutionPlanId: planID, PageIndex: index}
	for _, c := range cidrs {
		page.Ranges = append(page.Ranges, &edgev1.TargetRangeV1{Cidr: c, TargetCount: 256})
	}
	d, err := PageDigest(page)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	page.PageSha256 = d
	return page
}

func makePlan(t *testing.T, planID []byte, pages ...*edgev1.ScheduledPlanPageV1) *Plan {
	t.Helper()
	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId:  planID,
		PageCount:        uint32(len(pages)),
		TotalTargetCount: uint64(len(pages)) * 256,
	}
	for _, pg := range pages {
		header.PageSha256 = append(header.PageSha256, pg.GetPageSha256())
	}
	header.ExecutionPlanSha256 = HeaderDigest(header)
	plan, err := NewPlan(header)
	if err != nil {
		t.Fatalf("new plan: %v", err)
	}
	return plan
}

func TestPageDigestDeterministic(t *testing.T) {
	id := make([]byte, 16)
	a := makePage(t, id, 0, "10.0.0.0/24", "10.0.1.0/24")
	b := makePage(t, id, 0, "10.0.0.0/24", "10.0.1.0/24")
	if string(a.GetPageSha256()) != string(b.GetPageSha256()) {
		t.Fatal("identical pages produced different digests")
	}
	c := makePage(t, id, 0, "10.0.1.0/24", "10.0.0.0/24") // reordered
	if string(a.GetPageSha256()) == string(c.GetPageSha256()) {
		t.Fatal("reordered ranges must change the digest")
	}
}

func TestForEachRangeIteratesAllPagesOnce(t *testing.T) {
	id := make([]byte, 16)
	id[0] = 0x11
	p0 := makePage(t, id, 0, "10.0.0.0/24", "10.0.1.0/24")
	p1 := makePage(t, id, 1, "192.168.0.0/24")
	plan := makePlan(t, id, p0, p1)

	pages := map[uint32]*edgev1.ScheduledPlanPageV1{0: p0, 1: p1}
	fetched := make([]uint32, 0)
	var cidrs []string
	err := plan.ForEachRange(
		func(i uint32) (*edgev1.ScheduledPlanPageV1, error) {
			fetched = append(fetched, i)
			return pages[i], nil
		},
		func(_ uint32, r *edgev1.TargetRangeV1) error {
			cidrs = append(cidrs, r.GetCidr())
			return nil
		},
	)
	if err != nil {
		t.Fatalf("for each: %v", err)
	}
	if len(fetched) != 2 || fetched[0] != 0 || fetched[1] != 1 {
		t.Fatalf("pages fetched out of order or repeated: %v", fetched)
	}
	if len(cidrs) != 3 {
		t.Fatalf("want 3 ranges, got %d: %v", len(cidrs), cidrs)
	}
}

func TestValidatePageRejectsTamperedDigest(t *testing.T) {
	id := make([]byte, 16)
	page := makePage(t, id, 0, "10.0.0.0/24")
	plan := makePlan(t, id, page)

	// Tamper the ranges after the header committed to the original digest.
	tampered := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: id,
		PageIndex:       0,
		PageSha256:      page.GetPageSha256(),
		Ranges:          []*edgev1.TargetRangeV1{{Cidr: "0.0.0.0/0", TargetCount: 1 << 32}},
	}
	if err := plan.ValidatePage(0, tampered); err != ErrPageDigestMismatch {
		t.Fatalf("want ErrPageDigestMismatch, got %v", err)
	}
}

func TestValidatePageRejectsWrongPlan(t *testing.T) {
	id := make([]byte, 16)
	id[0] = 0x01
	other := make([]byte, 16)
	other[0] = 0x02
	page := makePage(t, id, 0, "10.0.0.0/24")
	plan := makePlan(t, id, page)

	crossPage := makePage(t, other, 0, "10.0.0.0/24")
	if err := plan.ValidatePage(0, crossPage); err != ErrPagePlanMismatch {
		t.Fatalf("want ErrPagePlanMismatch, got %v", err)
	}
}

func TestValidatePageRejectsOutOfRangeIndex(t *testing.T) {
	id := make([]byte, 16)
	page := makePage(t, id, 0, "10.0.0.0/24")
	plan := makePlan(t, id, page)
	if err := plan.ValidatePage(1, page); !errors.Is(err, ErrPageIndexOutOfRange) {
		t.Fatalf("want ErrPageIndexOutOfRange, got %v", err)
	}
}

func TestNewPlanRejectsDigestCountMismatch(t *testing.T) {
	id := make([]byte, 16)
	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: id,
		PageCount:       3,
		PageSha256:      [][]byte{make([]byte, 32)}, // only 1 digest for 3 pages
	}
	if _, err := NewPlan(header); err == nil {
		t.Fatal("expected ErrHeaderInvalid for digest/page-count mismatch")
	}
}

// Finding usp-10/P1: NewPlan must reject a header whose recorded digest does not
// match its canonical self-excluding digest (a tampered header), and must
// require a present, correct digest.
func TestNewPlanRejectsTamperedHeader(t *testing.T) {
	id := make([]byte, 16)
	id[0] = 0x7A
	page := makePage(t, id, 0, "10.0.0.0/24")
	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId:  id,
		PageCount:        1,
		TotalTargetCount: 256,
		AssignmentEpoch:  9,
		PageSha256:       [][]byte{page.GetPageSha256()},
	}
	header.ExecutionPlanSha256 = HeaderDigest(header)

	// A valid header is accepted.
	if _, err := NewPlan(header); err != nil {
		t.Fatalf("valid header rejected: %v", err)
	}
	// Tamper a covered field after the digest was computed.
	header.AssignmentEpoch = 10
	if _, err := NewPlan(header); !errors.Is(err, ErrHeaderDigestMismatch) {
		t.Fatalf("tampered epoch = %v, want ErrHeaderDigestMismatch", err)
	}
	// Tamper the page-digest list.
	header.AssignmentEpoch = 9
	header.PageSha256[0] = make([]byte, 32) // wrong (but 32-byte) digest
	if _, err := NewPlan(header); !errors.Is(err, ErrHeaderDigestMismatch) {
		t.Fatalf("tampered page digest = %v, want ErrHeaderDigestMismatch", err)
	}
}

// Finding usp-10/P1: non-32-byte digests are rejected.
func TestNewPlanRejectsBadDigestLength(t *testing.T) {
	id := make([]byte, 16)
	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: id,
		PageCount:       1,
		PageSha256:      [][]byte{make([]byte, 16)}, // too short
	}
	header.ExecutionPlanSha256 = HeaderDigest(header)
	if _, err := NewPlan(header); !errors.Is(err, ErrDigestLength) {
		t.Fatalf("short page digest = %v, want ErrDigestLength", err)
	}
}

// Finding usp-10/P1: NewVerifiedPlan binds the plan to a trusted expected digest.
func TestNewVerifiedPlanBindsExpectedDigest(t *testing.T) {
	id := make([]byte, 16)
	id[0] = 0x33
	page := makePage(t, id, 0, "10.0.0.0/24")
	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: id,
		PageCount:       1,
		PageSha256:      [][]byte{page.GetPageSha256()},
	}
	header.ExecutionPlanSha256 = HeaderDigest(header)

	if _, err := NewVerifiedPlan(header, header.GetExecutionPlanSha256()); err != nil {
		t.Fatalf("matching expected digest rejected: %v", err)
	}
	wrong := make([]byte, 32)
	wrong[0] = 0xFF
	if _, err := NewVerifiedPlan(header, wrong); !errors.Is(err, ErrHeaderDigestMismatch) {
		t.Fatalf("wrong expected digest = %v, want ErrHeaderDigestMismatch", err)
	}
}
