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

// Package targetplan reads an immutable scheduler target plan as a bounded,
// content-addressed page store. A plan is a small header that lists the SHA-256
// digest of every range page; the agent fetches and validates one page at a
// time and iterates its compact CIDR ranges, so an arbitrarily large target set
// (a /8, a million hosts) is never materialized as an execution-wide array in
// config, memory, or terminal evidence. This is the read side of task 2.3a.
package targetplan

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var (
	// ErrPageIndexOutOfRange is returned when a page index is not < page_count.
	ErrPageIndexOutOfRange = errors.New("targetplan: page index out of range")
	// ErrPageDigestMismatch is returned when a fetched page's content digest
	// does not match the header's recorded digest for that index.
	ErrPageDigestMismatch = errors.New("targetplan: page content digest mismatch")
	// ErrPagePlanMismatch is returned when a page names a different plan than the
	// header it is validated against.
	ErrPagePlanMismatch = errors.New("targetplan: page belongs to a different plan")
	// ErrHeaderInvalid is returned when the header is internally inconsistent.
	ErrHeaderInvalid = errors.New("targetplan: header invalid")
	// ErrDigestLength is returned when a page or header digest is not a 32-byte
	// SHA-256 value.
	ErrDigestLength = errors.New("targetplan: digest is not 32 bytes")
	// ErrHeaderDigestMismatch is returned when a header's self-excluding canonical
	// digest does not match its recorded execution_plan_sha256 (or a trusted
	// expected digest). A tampered header is thereby rejected before it can drive
	// a different target set.
	ErrHeaderDigestMismatch = errors.New("targetplan: header digest mismatch")
)

const sha256Len = 32

// HeaderDigest computes the canonical, self-excluding digest of a plan header:
// it covers execution_plan_id, page_count, total_target_count, assignment_epoch,
// network_scope_id, and every page_sha256 in order -- but NOT the header's own
// execution_plan_sha256 field. Every variable-length field is length-prefixed so
// distinct headers cannot canonicalize to the same bytes.
func HeaderDigest(h *edgev1.ScheduledPlanHeaderV1) []byte {
	hh := sha256.New()
	var num [8]byte

	writeBytes := func(b []byte) {
		binary.BigEndian.PutUint64(num[:], uint64(len(b)))
		_, _ = hh.Write(num[:])
		_, _ = hh.Write(b)
	}
	writeU64 := func(v uint64) {
		binary.BigEndian.PutUint64(num[:], v)
		_, _ = hh.Write(num[:])
	}

	writeBytes(h.GetExecutionPlanId())
	writeU64(uint64(h.GetPageCount()))
	writeU64(h.GetTotalTargetCount())
	writeU64(h.GetAssignmentEpoch())
	writeBytes(h.GetNetworkScopeId())
	writeU64(uint64(len(h.GetPageSha256())))
	for _, d := range h.GetPageSha256() {
		writeBytes(d)
	}
	return hh.Sum(nil)
}

// PageFetcher returns the page at the given 0-based index. Implementations pull
// from wherever pages live (assignment payload, gateway, cache) and must not
// require the whole plan resident at once.
type PageFetcher func(index uint32) (*edgev1.ScheduledPlanPageV1, error)

// PageDigest computes the canonical content digest of a page's ranges. The
// digest covers only the ranges (not the enclosing page_index or stored
// page_sha256) in their given order, each length-prefixed and deterministically
// marshaled, so identical range sets in identical order yield identical bytes.
func PageDigest(page *edgev1.ScheduledPlanPageV1) ([]byte, error) {
	h := sha256.New()
	var lp [8]byte
	for _, r := range page.GetRanges() {
		b, err := proto.MarshalOptions{Deterministic: true}.Marshal(r)
		if err != nil {
			return nil, fmt.Errorf("targetplan: marshal range: %w", err)
		}
		binary.BigEndian.PutUint64(lp[:], uint64(len(b)))
		_, _ = h.Write(lp[:])
		_, _ = h.Write(b)
	}
	return h.Sum(nil), nil
}

// Plan wraps a validated immutable plan header and drives bounded page-at-a-time
// iteration. It never retains more than one page.
type Plan struct {
	header *edgev1.ScheduledPlanHeaderV1
}

// NewPlan validates a header's internal consistency and content-address
// integrity, then returns a Plan. It requires exactly page_count page digests,
// a non-empty execution_plan_id, 32-byte page and header digests, and that the
// recorded execution_plan_sha256 equals the header's self-excluding canonical
// digest. This rejects a tampered header, but proves integrity only -- use
// NewVerifiedPlan to also bind the plan to a trusted (signed) expected digest.
func NewPlan(header *edgev1.ScheduledPlanHeaderV1) (*Plan, error) {
	if header == nil {
		return nil, ErrHeaderInvalid
	}
	if int(header.GetPageCount()) != len(header.GetPageSha256()) {
		return nil, fmt.Errorf("%w: page_count=%d but %d digests", ErrHeaderInvalid,
			header.GetPageCount(), len(header.GetPageSha256()))
	}
	if len(header.GetExecutionPlanId()) == 0 {
		return nil, fmt.Errorf("%w: missing execution_plan_id", ErrHeaderInvalid)
	}
	for i, d := range header.GetPageSha256() {
		if len(d) != sha256Len {
			return nil, fmt.Errorf("%w: page %d digest is %d bytes", ErrDigestLength, i, len(d))
		}
	}
	if len(header.GetExecutionPlanSha256()) != sha256Len {
		return nil, fmt.Errorf("%w: header digest is %d bytes", ErrDigestLength, len(header.GetExecutionPlanSha256()))
	}
	if !bytesEqual(HeaderDigest(header), header.GetExecutionPlanSha256()) {
		return nil, ErrHeaderDigestMismatch
	}
	return &Plan{header: header}, nil
}

// NewVerifiedPlan is NewPlan plus an authenticity check: the header's canonical
// digest must equal expectedDigest, which the caller obtained from a trusted
// source (a scheduler-signed assignment). This binds the plan pages, epoch, and
// network scope to what the scheduler authorized, not merely to a self-consistent
// header.
func NewVerifiedPlan(header *edgev1.ScheduledPlanHeaderV1, expectedDigest []byte) (*Plan, error) {
	p, err := NewPlan(header)
	if err != nil {
		return nil, err
	}
	if len(expectedDigest) != sha256Len || !bytesEqual(expectedDigest, header.GetExecutionPlanSha256()) {
		return nil, fmt.Errorf("%w: does not match trusted expected digest", ErrHeaderDigestMismatch)
	}
	return p, nil
}

// PageCount reports how many range pages the plan has.
func (p *Plan) PageCount() uint32 { return p.header.GetPageCount() }

// TotalTargetCount reports the advisory sum of targets across all pages.
func (p *Plan) TotalTargetCount() uint64 { return p.header.GetTotalTargetCount() }

// ValidatePage checks that a fetched page belongs to this plan, sits at the
// expected index, and hashes to the header's recorded digest for that index.
func (p *Plan) ValidatePage(index uint32, page *edgev1.ScheduledPlanPageV1) error {
	if index >= p.header.GetPageCount() {
		return fmt.Errorf("%w: index %d >= page_count %d", ErrPageIndexOutOfRange, index, p.header.GetPageCount())
	}
	if !bytesEqual(page.GetExecutionPlanId(), p.header.GetExecutionPlanId()) {
		return ErrPagePlanMismatch
	}
	if page.GetPageIndex() != index {
		return fmt.Errorf("%w: page reports index %d, fetched as %d", ErrPageDigestMismatch, page.GetPageIndex(), index)
	}
	digest, err := PageDigest(page)
	if err != nil {
		return err
	}
	if !bytesEqual(digest, p.header.GetPageSha256()[index]) {
		return ErrPageDigestMismatch
	}
	// A page carrying its own page_sha256 must agree with the computed digest.
	if stored := page.GetPageSha256(); len(stored) > 0 && !bytesEqual(stored, digest) {
		return ErrPageDigestMismatch
	}
	return nil
}

// ForEachRange fetches, validates, and visits every range page in order,
// holding at most one page in memory at a time. Iteration stops and returns the
// first error from the fetcher, validation, or the visitor.
func (p *Plan) ForEachRange(fetch PageFetcher, visit func(page uint32, r *edgev1.TargetRangeV1) error) error {
	for index := uint32(0); index < p.header.GetPageCount(); index++ {
		page, err := fetch(index)
		if err != nil {
			return fmt.Errorf("targetplan: fetch page %d: %w", index, err)
		}
		if err := p.ValidatePage(index, page); err != nil {
			return err
		}
		for _, r := range page.GetRanges() {
			if err := visit(index, r); err != nil {
				return err
			}
		}
		page = nil //nolint:ineffassign // release the page before the next fetch
		_ = page
	}
	return nil
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
