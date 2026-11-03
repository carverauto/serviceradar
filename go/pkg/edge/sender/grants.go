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

package sender

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Delivery after reconnect (unify-sweep-results-proto M2.0g).
//
// A spooled record carries the production grant it was produced under, and its
// bytes are immutable. An agent disconnected past that grant's window holds a
// backlog the gateway refuses as expired authority: without a separate
// authority those records could never drain. Before each session the sender
// therefore asks for a same-spool RENEWAL delivery grant for every record in
// the window it is about to send whose production grant has lapsed, or is
// within renewalMargin of lapsing by this agent's clock, and attaches it to
// that record's frame. A grant only lets the exact bytes drain on their exact
// coordinate: the gateway still checks the record's event time against its
// original collection window and applies the current fence.
//
// Grants live in memory only. A restarted sender asks again, which costs one
// request per window rather than a durable grant store.

const (
	// renewalMargin is how far ahead of expiry a grant is requested or
	// refreshed: the gateway's clock tolerance, so a record this agent's clock
	// still calls current is not refused by a gateway clock that runs ahead.
	renewalMargin = edgerecord.MaxClockToleranceNano * time.Nanosecond

	// The bounds the gateway enforces on one RenewEdgeDeliveryGrants request.
	maxGrantRecordsPerRequest = 64
	maxGrantBytesPerRequest   = 2 << 20
)

// errGrantMismatch is returned for a grant that does not bind the record it was
// asked for. The sender drops it and delivers that record without a grant.
var errGrantMismatch = errors.New("sender: delivery grant does not bind its record")

// GrantRenewer obtains delivery grants for spooled records of one spool lane.
// It returns the grants it was given, keyed by sequence; a record core or the
// gateway refused is simply absent.
type GrantRenewer interface {
	RenewDeliveryGrants(ctx context.Context, spoolID []byte, records []spool.Record) (map[uint64]*edgev1.EdgeSignedCapabilityV1, error)
}

type heldGrant struct {
	capability   *edgev1.EdgeSignedCapabilityV1
	recordSHA256 [sha256.Size]byte
}

// renewGrants requests grants for the records the next session will send whose
// production authority has lapsed and that hold no current grant. A renewal
// failure is returned for the caller to report; the session still sends, so
// records under current authority are never held back by it.
func (s *Sender) renewGrants(ctx context.Context) error {
	if s.cfg.Grants == nil {
		return nil
	}
	now := s.now()
	s.dropResolvedGrants()

	var (
		need       []spool.Record
		frames     uint32
		bytesInWin uint64
	)
	scanErr := s.spool.ScanFrom(0, func(rec spool.Record) bool {
		if frames >= s.cfg.RequestedFrameCredits || bytesInWin+uint64(len(rec.Body)) > s.cfg.RequestedByteCredits {
			return false
		}
		frames++
		bytesInWin += uint64(len(rec.Body))
		if s.holdsCurrentGrant(rec, now) || !authorityLapsing(rec.Body, now) {
			return true
		}
		need = append(need, rec)
		return true
	})
	if scanErr != nil {
		return fmt.Errorf("sender: scan spool for delivery grants: %w", scanErr)
	}

	var errs []error
	for _, batch := range grantBatches(need) {
		granted, err := s.cfg.Grants.RenewDeliveryGrants(ctx, s.cfg.SpoolID, batch)
		if err != nil {
			errs = append(errs, fmt.Errorf("sender: renew delivery grants: %w", err))
			continue
		}
		for _, rec := range batch {
			if capability, ok := granted[rec.Sequence]; ok {
				if err := s.holdGrant(rec, capability); err != nil {
					errs = append(errs, err)
				}
			}
		}
	}
	return errors.Join(errs...)
}

// authorityLapsing reports whether the record's production grant expires within
// renewalMargin of now. A record that does not decode is left to the gateway,
// which rejects it on its own terms.
func authorityLapsing(body []byte, now time.Time) bool {
	record, err := edgerecord.DecodeRecord(body)
	if err != nil {
		return false
	}
	expires := record.GetProductionCapability().GetExpiresAtUnixNano()
	return now.Add(renewalMargin).UnixNano() >= expires
}

func (s *Sender) holdsCurrentGrant(rec spool.Record, now time.Time) bool {
	held, ok := s.grants[rec.Sequence]
	if !ok || held.recordSHA256 != sha256.Sum256(rec.Body) {
		return false
	}
	return now.Add(renewalMargin).UnixNano() < held.capability.GetExpiresAtUnixNano()
}

// holdGrant keeps a grant only if it binds this record on this lane, checked the
// way the gateway will check the frame that carries it.
func (s *Sender) holdGrant(rec spool.Record, capability *edgev1.EdgeSignedCapabilityV1) error {
	frame := buildFrame(s.cfg.SpoolID, rec)
	frame.DeliveryCapability = capability
	if err := edgerecord.ValidateDeliveryFrame(frame, false); err != nil {
		return fmt.Errorf("%w: seq=%d: %w", errGrantMismatch, rec.Sequence, err)
	}
	s.grants[rec.Sequence] = heldGrant{capability: capability, recordSHA256: sha256.Sum256(rec.Body)}
	return nil
}

// grantFor is the held grant for a record about to be sent, if it still binds
// these exact bytes.
func (s *Sender) grantFor(rec spool.Record) *edgev1.EdgeSignedCapabilityV1 {
	held, ok := s.grants[rec.Sequence]
	if !ok || held.recordSHA256 != sha256.Sum256(rec.Body) {
		return nil
	}
	return held.capability
}

func (s *Sender) dropResolvedGrants() {
	resolved := s.spool.Resolved()
	for sequence := range s.grants {
		if sequence <= resolved {
			delete(s.grants, sequence)
		}
	}
}

func (s *Sender) now() time.Time {
	if s.cfg.Now != nil {
		return s.cfg.Now()
	}
	return time.Now()
}

// grantBatches splits records into requests within the gateway's bounds.
func grantBatches(records []spool.Record) [][]spool.Record {
	var batches [][]spool.Record
	start, size := 0, 0
	for i, rec := range records {
		if i > start && (i-start == maxGrantRecordsPerRequest || size+len(rec.Body) > maxGrantBytesPerRequest) {
			batches = append(batches, records[start:i])
			start, size = i, 0
		}
		size += len(rec.Body)
	}
	if start < len(records) {
		batches = append(batches, records[start:])
	}
	return batches
}
