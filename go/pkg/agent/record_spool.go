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
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/fairsched"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// RecordSpool owns bounded producer lanes. Existing flat storage is retained
// untouched and charged to the same allocator, but never opened or delivered.
type RecordSpool struct {
	activeMu    sync.Mutex
	active      bool
	lanes       *spool.LaneSet
	taxonomy    *fairsched.LaneTaxonomy
	allocator   *spool.Allocator
	legacyBytes uint64
	trust       func() *edgerecord.TrustSnapshot
}

// OpenRecordSpool inventories retained files without interpreting them, then
// opens independent bounded lanes. Every file charges allocator once.
func OpenRecordSpool(root string, allocator *spool.Allocator, options ...spool.Option) (*RecordSpool, error) {
	if allocator == nil {
		return nil, spool.ErrInvalidAllocatorConfig
	}
	recovery := spool.LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
	bulk := spool.LaneKey{RouteProfile: edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, TrafficClass: edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK}
	taxonomy, err := fairsched.NewLaneTaxonomy([]fairsched.LanePolicy{{Key: bulk, WeightBytes: 1}, {Key: recovery, WeightBytes: 1}}, recovery)
	if err != nil {
		return nil, err
	}
	common := append(append([]spool.Option{}, options...), spool.WithAllocator(allocator))
	retained, err := retainedStorageBytes(root)
	if err != nil {
		return nil, err
	}
	allocator.ChargeMeasured(root, retained)
	lanes, err := spool.OpenRetainedLanes(filepath.Join(root, "lanes"), taxonomy, spool.WithLaneAllocator(allocator), spool.WithGenerationOptions(func(id spool.GenerationIdentity, _ string) ([]spool.Option, error) {
		return append(append([]spool.Option{}, common...), spool.WithAttribution(id)), nil
	}))
	if err != nil {
		return nil, err
	}
	return &RecordSpool{lanes: lanes, taxonomy: taxonomy, allocator: allocator, legacyBytes: retained}, nil
}

// Lanes returns the storage owner shared by producers and recovery coordination.
func (s *RecordSpool) Lanes() *spool.LaneSet { return s.lanes }

// DeliveryLanes is the finite configured taxonomy, including lanes with no
// generation yet. Sender workers therefore exist before their first append.
func (s *RecordSpool) DeliveryLanes() []spool.LaneKey { return s.taxonomy.Lanes() }

// RetainedLegacyBytes are unsupported flat-storage bytes, never sender input.
func (s *RecordSpool) RetainedLegacyBytes() uint64 { return s.legacyBytes }

func retainedStorageBytes(root string) (uint64, error) {
	var total uint64
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if errors.Is(walkErr, os.ErrNotExist) && path == root {
			return nil
		}
		if walkErr != nil {
			return walkErr
		}
		if path == root && !entry.IsDir() {
			return errors.New("edge storage root must be a directory")
		}
		if path == filepath.Join(root, "lanes") {
			return filepath.SkipDir
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		total += uint64(info.Size())
		return nil
	})
	return total, err
}

// SetTrustProvider is wired before producers start. Missing policy is retryable;
// previously prepared records keep the immutable decision made at construction.
func (s *RecordSpool) SetTrustProvider(provider func() *edgerecord.TrustSnapshot) { s.trust = provider }

// Ready reports whether new producer work can obtain authenticated policy.
func (s *RecordSpool) Ready() bool { return s != nil && s.trust != nil && s.trust() != nil }

// PrepareRecord seals the exact record only after its registered typed validator
// proves signed authority and the body/identity join. It precedes admission, so
// an expired or replaced grant never changes already-produced pending bytes.
func (s *RecordSpool) PrepareRecord(raw []byte) (*spool.AttributedAppend, error) {
	if s.trust == nil {
		return nil, edgerecord.ErrTrustMissing
	}
	snapshot := s.trust()
	record, err := edgerecord.DecodeRecord(raw)
	if err != nil {
		return nil, errors.Join(spool.ErrPermanent, err)
	}
	policy, err := snapshot.PolicyFor(record, time.Now().UnixNano())
	if err != nil {
		return nil, err
	}
	validated, err := edgerecord.RecordRecoveryAttribution(raw, record.GetOutputContract(), policy)
	if err != nil {
		return nil, attributionRefusal(err)
	}
	identity := spool.Identity{NetworkScopeID: record.GetNetworkScopeId(), AgentID: record.GetProducerContext().GetOriginPrincipalId()}
	if err = s.activate(identity, true); err != nil {
		return nil, err
	}
	return &spool.AttributedAppend{EventID: bytes.Clone(record.GetEventId()), Body: bytes.Clone(raw), Validated: validated}, nil
}

// Authority can change independently of immutable record semantics. Keep those
// refusals pending; a typed body or envelope mismatch cannot heal on retry.
func attributionRefusal(err error) error {
	for _, pending := range []error{
		edgerecord.ErrTrustMissing, edgerecord.ErrTrustEpochUnset,
		edgerecord.ErrKeyUnavailable, edgerecord.ErrCapabilityKeyUnresolved,
		edgerecord.ErrKeyHistoricallyRevoked, edgerecord.ErrFenceNotReady,
		edgerecord.ErrFenceStale, edgerecord.ErrAuthorityExpired, edgerecord.ErrAuthorityNotYetValid,
	} {
		if errors.Is(err, pending) {
			return err
		}
	}
	return errors.Join(spool.ErrPermanent, err)
}

// AppendPrepared retries rotation once with the same sealed bytes. A second
// refusal remains retryable and is retained by the producer's bounded queue.
func (s *RecordSpool) AppendPrepared(flow string, prepared *spool.AttributedAppend) (spool.Receipt, error) {
	if prepared == nil {
		return spool.Receipt{}, spool.ErrAttributionRequired
	}
	record, err := edgerecord.DecodeRecord(prepared.Body)
	if err != nil {
		return spool.Receipt{}, errors.Join(spool.ErrPermanent, err)
	}
	key := spool.LaneKey{RouteProfile: record.GetRouteProfile(), TrafficClass: record.GetTrafficClass()}
	identity := spool.Identity{NetworkScopeID: record.GetNetworkScopeId(), AgentID: record.GetProducerContext().GetOriginPrincipalId()}
	hash := sha256.Sum256(prepared.Body)
	if err = prepared.Validated.CheckRecord(edgerecord.LocalBindingCoordinates{NetworkScopeID: identity.NetworkScopeID, AuthenticatedAgentID: identity.AgentID, LaneRouteProfile: key.RouteProfile, LaneTrafficClass: key.TrafficClass, EventID: prepared.EventID, RecordSHA256: hash[:]}); err != nil {
		return spool.Receipt{}, errors.Join(spool.ErrPermanent, err)
	}
	if err = s.activate(identity, false); err != nil {
		return spool.Receipt{}, err
	}
	receipt, err := s.lanes.AppendAttributedFlow(flow, key, identity, *prepared)
	if errors.Is(err, spool.ErrRotationRequired) {
		if _, err = s.lanes.Rotate(key); err != nil {
			return spool.Receipt{}, err
		}
		receipt, err = s.lanes.AppendAttributedFlow(flow, key, identity, *prepared)
	}
	return receipt, err
}

// A retained in-memory seal can initialize a replacement storage handle after
// admission failed. It cannot replace an already activated namespace. Only new
// construction under current authenticated policy can do that.
func (s *RecordSpool) activate(identity spool.Identity, replace bool) error {
	s.activeMu.Lock()
	defer s.activeMu.Unlock()
	if s.active && !replace {
		return nil
	}
	if err := s.lanes.ActivateSession(identity); err != nil {
		return err
	}
	s.active = true
	return nil
}

func (s *RecordSpool) Close() error { return s.lanes.Close() }

// RecordSource carries delivery and health operations for one immutable sequence
// namespace. It exposes no raw append bypass.
type RecordSource interface {
	ScanFrom(uint64, func(spool.Record) bool) error
	Resolved() uint64
	ReclaimResolved() error
	CoverageGap(uint64) (spool.SlotResolution, bool)
	ResolveWithEvidence(uint64, []byte) error
	Health(time.Time) (spool.Health, error)
	QuarantineHealth() (spool.QuarantineHealth, error)
	RestartResolution() spool.Resolution
}

type RecordSpoolSource struct {
	Identity spool.GenerationIdentity
	Source   RecordSource
}

// RecordSpoolCursor is bounded state for a sequential round-robin inventory.
// Reset it after NextSource reports false to begin another pass.
type RecordSpoolCursor struct {
	lane    int
	ordinal uint64
}

func (s *RecordSpool) NextSource(cursor *RecordSpoolCursor) (RecordSpoolSource, bool) {
	keys := s.DeliveryLanes()
	for cursor.lane < len(keys) {
		if source, ok := s.NextLaneSource(keys[cursor.lane], &cursor.ordinal); ok {
			return source, true
		}
		cursor.lane++
		cursor.ordinal = 0
	}
	return RecordSpoolSource{}, false
}

// NextLaneSource advances one lane's independent bounded generation cursor.
func (s *RecordSpool) NextLaneSource(key spool.LaneKey, ordinal *uint64) (RecordSpoolSource, bool) {
	page := s.lanes.GenerationsPage(key, *ordinal, 1)
	if len(page) == 0 {
		return RecordSpoolSource{}, false
	}
	g := page[0]
	identity := g.Identity()
	*ordinal = identity.Ordinal
	return RecordSpoolSource{Identity: identity, Source: g}, true
}

// edgePreparedRecord lives inside an existing bounded producer queue entry.
// The seal is minted before first admission and survives every refusal unchanged.
type edgePreparedRecord struct{ value *spool.AttributedAppend }

func (p *edgePreparedRecord) prepare(app edgeMetricsAppender, record *edgev1.EdgeRecordV1, raw []byte) error {
	if p.value != nil {
		return nil
	}
	if raw == nil {
		var err error
		raw, err = edgerecord.CanonicalRecordBytes(record)
		if err != nil {
			return errors.Join(spool.ErrPermanent, err)
		}
	}
	value, err := app.PrepareRecord(raw)
	if err != nil {
		return err
	}
	p.value = value
	return nil
}

func (p *edgePreparedRecord) append(app edgeMetricsAppender, record *edgev1.EdgeRecordV1, raw []byte) error {
	if err := p.prepare(app, record, raw); err != nil {
		return err
	}
	_, err := app.AppendPrepared(edgeAdmissionFlow(record), p.value)
	return err
}

func prepareRecordParts(app edgeMetricsAppender, records []*edgev1.EdgeRecordV1, bodies [][]byte, prepared *[]edgePreparedRecord) error {
	if len(*prepared) == 0 {
		*prepared = make([]edgePreparedRecord, len(records))
	}
	for i, record := range records {
		if err := (*prepared)[i].prepare(app, record, bodies[i]); err != nil {
			return err
		}
	}
	return nil
}

func prepareMetricParts(app edgeMetricsAppender, parts []edgeMetricsBuilt) error {
	for i := range parts {
		if err := parts[i].prepared.prepare(app, parts[i].record, nil); err != nil {
			return err
		}
	}
	return nil
}
