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
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/fairsched"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
)

// Late admission (openspec add-edge-production-time-admission).
//
// A committed record whose live admission is no longer possible -- a legacy layout
// left it behind, or the gateway resolved it LATE_ADMISSION_REQUIRED because its
// fence went stale or missing -- is admitted LATE under the production-time rule
// into storage that never feeds a live session:
//
//	<root>/late/own/<lane>/<generation>        the host's own records
//	<root>/late/hold/<origin principal hex>/... records whose origin is another
//	                                            principal (a revoked or superseded
//	                                            predecessor): security quarantine only
//
// Each is an ordinary bounded LaneSet charged to the shared allocator, so a hold
// is keyed by (lane key, origin principal) and drains on that lane key's late
// session without blocking the host's own late records behind a grant wait.

const (
	lateOwnEntry  = "own"
	lateHoldEntry = "hold"
)

// LateDestination says where AdmitLate put a record.
type LateDestination uint8

const (
	// LateDestinationOwn -- the host's own late generation; core decides PRIMARY/AUDIT.
	LateDestinationOwn LateDestination = iota + 1
	// LateDestinationHold -- a foreign-origin hold; security quarantine only.
	LateDestinationHold
)

// LateReceipt identifies a durably admitted late record.
type LateReceipt struct {
	Destination LateDestination
	Outcome     edgerecord.LateOutcome
	Receipt     spool.Receipt
}

// lateStore owns the late LaneSets of one record root.
type lateStore struct {
	root      string
	taxonomy  *fairsched.LaneTaxonomy
	allocator *spool.Allocator
	options   []spool.Option

	mu    sync.Mutex
	own   *spool.LaneSet
	holds map[string]*spool.LaneSet // keyed by origin principal bytes

	// admitMu makes one admission's duplicate check, session activation and append
	// atomic: a LaneSet has a single session, and the handoff and relocation admit
	// concurrently.
	admitMu sync.Mutex
}

func openLateStore(root string, taxonomy *fairsched.LaneTaxonomy, allocator *spool.Allocator, options []spool.Option) (*lateStore, error) {
	store := &lateStore{root: filepath.Join(root, spool.LateRootEntry), taxonomy: taxonomy, allocator: allocator, options: options, holds: make(map[string]*spool.LaneSet)}
	own, err := store.openLanes(filepath.Join(store.root, lateOwnEntry))
	if err != nil {
		return nil, err
	}
	store.own = own
	entries, err := os.ReadDir(filepath.Join(store.root, lateHoldEntry))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, entry := range entries {
		principal, decodeErr := hex.DecodeString(entry.Name())
		if decodeErr != nil || !entry.IsDir() || edgerecord.ValidateAuthenticatedPrincipal(principal) != nil {
			return nil, fmt.Errorf("%w: late hold %q", spool.ErrCorruptGeneration, entry.Name())
		}
		hold, openErr := store.openLanes(filepath.Join(store.root, lateHoldEntry, entry.Name()))
		if openErr != nil {
			return nil, openErr
		}
		store.holds[string(principal)] = hold
	}
	return store, nil
}

func (l *lateStore) openLanes(dir string) (*spool.LaneSet, error) {
	return spool.OpenRetainedLanes(dir, l.taxonomy, spool.WithLaneAllocator(l.allocator), spool.WithGenerationOptions(func(id spool.GenerationIdentity, _ string) ([]spool.Option, error) {
		return append(append([]spool.Option{}, l.options...), spool.WithAttribution(id)), nil
	}))
}

// laneSetFor returns the LaneSet a record of origin belongs in, opening a hold on
// first use.
func (l *lateStore) laneSetFor(origin []byte, own bool) (*spool.LaneSet, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if own {
		return l.own, nil
	}
	if hold, ok := l.holds[string(origin)]; ok {
		return hold, nil
	}
	hold, err := l.openLanes(filepath.Join(l.root, lateHoldEntry, hex.EncodeToString(origin)))
	if err != nil {
		return nil, err
	}
	l.holds[string(origin)] = hold
	return hold, nil
}

// sets returns every late LaneSet: the host's own first, then holds.
func (l *lateStore) sets() []*spool.LaneSet {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := []*spool.LaneSet{l.own}
	for _, hold := range l.holds {
		out = append(out, hold)
	}
	return out
}

func (l *lateStore) close() error {
	var errs []error
	for _, set := range l.sets() {
		errs = append(errs, set.Close())
	}
	return errors.Join(errs...)
}

// holdsRecord returns the receipt of an unresolved copy of these exact bytes
// already in the lane; admitLate asks every late LaneSet, own and holds, so a
// retry whose destination changed still finds the copy, so a crash between a late append and the source's local
// resolution leaves one copy and the source records that copy's generation as
// custody. It sees only bytes still on disk: a copy a late session already
// delivered and reclaimed is not detected locally, and a re-admitted copy is a
// replay no-op under core's event-ledger idempotency (phase 2, which must be
// deployed before any late session sends).
func holdsRecord(set *spool.LaneSet, key spool.LaneKey, eventID, body []byte) (spool.Receipt, bool, error) {
	for _, generation := range set.Generations(key) {
		var receipt spool.Receipt
		found := false
		err := generation.ScanFrom(generation.Resolved(), func(rec spool.Record) bool {
			if bytes.Equal(rec.EventID, eventID) && bytes.Equal(rec.Body, body) {
				receipt, found = spool.Receipt{Generation: generation.Identity(), Sequence: rec.Sequence}, true
				return false
			}
			return true
		})
		if err != nil || found {
			return receipt, found, err
		}
	}
	return spool.Receipt{}, false, nil
}

// AdmitLate validates raw under the production-time rule and durably appends it
// to the late generation of its lane key, or, when its origin is another principal,
// to that principal's hold. It never falls back to live admission.
//
// Errors carry the rule's classes: ErrTrustMissing / ErrTrustEpochUnset and
// ErrKeyUnavailable are retryable; anything joined with spool.ErrPermanent (an
// invalid structure, body or key) can never be admitted and belongs in rejection
// evidence.
func (s *RecordSpool) AdmitLate(raw []byte) (LateReceipt, error) {
	return s.admitLate(raw, false)
}

func (s *RecordSpool) admitLate(raw []byte, checkDuplicate bool) (LateReceipt, error) {
	if s.trust == nil {
		return LateReceipt{}, edgerecord.ErrTrustMissing
	}
	snapshot := s.trust()
	if snapshot == nil {
		return LateReceipt{}, edgerecord.ErrTrustMissing
	}
	record, err := edgerecord.DecodeRecord(raw)
	if err != nil {
		return LateReceipt{}, errors.Join(spool.ErrPermanent, err)
	}
	policy, err := snapshot.LatePolicyFor(record, time.Now().UnixNano())
	if err != nil {
		return LateReceipt{}, err
	}
	validated, outcome, err := edgerecord.RecordLateAttribution(raw, record.GetOutputContract(), policy)
	if err != nil {
		return LateReceipt{}, lateRefusal(err)
	}
	origin := record.GetProducerContext().GetOriginPrincipalId()
	own := bytes.Equal(origin, snapshot.AuthenticatedAgent())
	destination := LateDestinationOwn
	if !own {
		// Another principal's bytes: security quarantine only, whatever their keys say.
		destination, outcome = LateDestinationHold, edgerecord.LateAdmissibleSecurity
	}
	key := spool.LaneKey{RouteProfile: record.GetRouteProfile(), TrafficClass: record.GetTrafficClass()}
	s.late.admitMu.Lock()
	defer s.late.admitMu.Unlock()
	if checkDuplicate {
		for i, held := range s.late.sets() {
			existing, found, holdErr := holdsRecord(held, key, record.GetEventId(), raw)
			if holdErr != nil {
				return LateReceipt{}, holdErr
			}
			if !found {
				continue
			}
			if i == 0 {
				return LateReceipt{Destination: LateDestinationOwn, Outcome: outcome, Receipt: existing}, nil
			}
			return LateReceipt{Destination: LateDestinationHold, Outcome: edgerecord.LateAdmissibleSecurity, Receipt: existing}, nil
		}
	}
	set, err := s.late.laneSetFor(origin, own)
	if err != nil {
		return LateReceipt{}, err
	}
	identity := spool.Identity{NetworkScopeID: record.GetNetworkScopeId(), AgentID: origin}
	if err = set.ActivateSession(identity); err != nil {
		return LateReceipt{}, err
	}
	prepared := spool.AttributedAppend{EventID: bytes.Clone(record.GetEventId()), Body: bytes.Clone(raw), Validated: validated}
	hash := sha256.Sum256(raw)
	if err = validated.CheckRecord(edgerecord.LocalBindingCoordinates{NetworkScopeID: identity.NetworkScopeID, AuthenticatedAgentID: identity.AgentID,
		LaneRouteProfile: key.RouteProfile, LaneTrafficClass: key.TrafficClass, EventID: prepared.EventID, RecordSHA256: hash[:]}); err != nil {
		return LateReceipt{}, errors.Join(spool.ErrPermanent, err)
	}
	receipt, err := set.AppendAttributedFlow(edgeAdmissionFlow(record), key, identity, prepared)
	if errors.Is(err, spool.ErrRotationRequired) {
		if _, err = set.Rotate(key); err != nil {
			return LateReceipt{}, err
		}
		receipt, err = set.AppendAttributedFlow(edgeAdmissionFlow(record), key, identity, prepared)
	}
	if err != nil {
		return LateReceipt{}, err
	}
	return LateReceipt{Destination: destination, Outcome: outcome, Receipt: receipt}, nil
}

// lateRefusal keeps only a missing snapshot and an UNAVAILABLE key retryable;
// every other refusal is permanent rejection evidence.
func lateRefusal(err error) error {
	for _, retryable := range []error{edgerecord.ErrTrustMissing, edgerecord.ErrTrustEpochUnset, edgerecord.ErrKeyUnavailable} {
		if errors.Is(err, retryable) {
			return err
		}
	}
	return errors.Join(spool.ErrPermanent, err)
}

// LateSource is one late generation to deliver on a LATE session.
type LateSource struct {
	RecordSpoolSource
	// Hold is true for a foreign-origin hold, whose frames are sent without waiting
	// for a grant and are always security-quarantined.
	Hold bool
}

// LateSources lists every late generation with unresolved records.
func (s *RecordSpool) LateSources() []LateSource {
	var out []LateSource
	for i, set := range s.late.sets() {
		for _, key := range set.Lanes() {
			for _, generation := range set.Generations(key) {
				if generation.NextSequence() == generation.Resolved()+1 {
					continue
				}
				out = append(out, LateSource{RecordSpoolSource: RecordSpoolSource{Identity: generation.Identity(), Source: generation}, Hold: i > 0})
			}
		}
	}
	return out
}

// LatePending counts unresolved late records.
func (s *RecordSpool) LatePending() uint64 {
	var count uint64
	for _, source := range s.LateSources() {
		generation := source.Source.(*spool.Generation)
		count += generation.NextSequence() - 1 - generation.Resolved()
	}
	return count
}

// RelocateLate is the sender hook for a LATE_ADMISSION_REQUIRED live disposition:
// the exact bytes go to late storage before the live resolution is persisted.
// A permanently invalid record is kept as rejection evidence instead; a full
// evidence store is retryable, so the live resolution waits rather than drop it.
//
// Until the source generation is fully resolved and reclaimed, a relocated record
// is charged twice. One acknowledgement adds at most one credit window of copies,
// because the gateway resolves only frames sent in that window, each charged at
// most spool.AttributedAppendCharge; the source bytes are released when the
// generation reclaims.
func (s *RecordSpool) RelocateLate(rec spool.Record) error {
	_, err := s.admitLate(rec.Body, true)
	if err != nil && errors.Is(err, spool.ErrPermanent) {
		// It can never be admitted late, and the live resolution will not copy it
		// into the quarantine: keep it as rejection evidence before the slot resolves.
		return s.rejections.write(rec.EventID, rec.Body, err.Error())
	}
	return err
}

// SetLatePeerProvider supplies the late-admission version the current gateway
// connection advertised in its accepted Hello.
func (s *RecordSpool) SetLatePeerProvider(provider func() uint32) { s.latePeer = provider }

// LatePeerVersion is the gateway's advertised late-admission version, or zero.
// Zero keeps every late generation on disk (late_pending_gateway_support) and
// keeps late-admission fields off lane_open, which an older gateway rejects.
func (s *RecordSpool) LatePeerVersion() uint32 {
	if s == nil || s.latePeer == nil {
		return 0
	}
	return s.latePeer()
}
