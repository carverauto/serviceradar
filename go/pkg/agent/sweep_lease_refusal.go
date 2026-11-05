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
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"time"

	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Leased slot refusals (openspec/changes/unify-sweep-results-proto, Decision
// 12): a slot whose signed checks this agent cannot run, or cannot run as
// signed, is refused with a typed reason instead of running a subset or a
// substitute. The refusal is persisted with the slot's executed mark and sent
// to core on the control stream, then re-sent on every connect until core can
// no longer judge the slot, because core records it idempotently by execution
// id and needs no acknowledgement.

const (
	// capabilityTCPSynIPv6Unavailable: a leased slot carried TCP SYN for an
	// IPv6 range this agent can only probe with connect. Core does not lease a
	// group whose check set needs IPv6 SYN to an agent reporting it.
	capabilityTCPSynIPv6Unavailable = "tcp_syn_ipv6.unavailable"
	// capabilitySweepLeasePlanChecksV1: this agent runs a leased slot from the
	// check set its push carries (check-set digest grammar 1), refuses
	// slot-carrying pushes at lease_version 1, and reports slot refusals. Core
	// leases only agents that report it.
	capabilitySweepLeasePlanChecksV1 = "sweep_lease_plan_checks:v1"

	sweepLeaseRefusalsSuffix = ".refusals.json"

	// sweepLeaseRefusalRetention is how long past a slot's collection expiry
	// the agent keeps re-sending its refusal: core's missed-run judgement
	// looks back this far (ServiceRadar.SweepJobs.LeaseMisses lookback).
	sweepLeaseRefusalRetention = 24 * time.Hour
)

// sweepSlotRefusal is an error that refuses one leased slot with the reason
// and capability markers core records.
type sweepSlotRefusal struct {
	reason  proto.SweepLeaseSlotRefusalReason
	markers []string
	detail  string
}

func (r *sweepSlotRefusal) Error() string {
	return fmt.Sprintf("leased sweep slot refused (%s): %s", r.reason, r.detail)
}

func refuseUnsupportedPlan(err error) error {
	return &sweepSlotRefusal{
		reason: proto.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_UNSUPPORTED_PLAN,
		detail: err.Error(),
	}
}

func refuseUnavailableChecks(markers []string, detail string) error {
	return &sweepSlotRefusal{
		reason:  proto.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE,
		markers: markers,
		detail:  detail,
	}
}

// unavailableSweepModeMarkers names the capability marker of each signed mode
// the scanner would not run as signed. The scanner only remaps raw SYN to
// connect, on IPv6 ranges without raw IPv6 SYN.
func unavailableSweepModeMarkers(signed, effective []models.SweepMode) []string {
	var markers []string

	for _, mode := range signed {
		if slices.Contains(effective, mode) {
			continue
		}

		switch mode {
		case models.ModeICMP:
			markers = append(markers, capabilityICMPUnavailable)
		case models.ModeTCP:
			markers = append(markers, capabilityTCPSynIPv6Unavailable)
		case models.ModeMTR:
			markers = append(markers, capabilityMTRUnavailable)
		case models.ModeTCPConnect:
		}
	}

	return markers
}

type sweepLeaseRefusalRecord struct {
	RetainUntilUnixNano int64  `json:"retain_until_unix_nano"`
	Refusal             []byte `json:"refusal"`
}

func (s *sweepLeaseStore) refusalsPath(groupID string) string {
	return filepath.Join(s.dir, groupID+sweepLeaseRefusalsSuffix)
}

func (s *sweepLeaseStore) loadRefusals(groupID string, data []byte, nowUnixNano int64) error {
	records := make(map[string]sweepLeaseRefusalRecord)
	if err := json.Unmarshal(data, &records); err != nil {
		return fmt.Errorf("decode sweep lease refusals %s: %w", groupID, err)
	}

	pruneRefusals(records, nowUnixNano)
	s.refusals[groupID] = records

	return nil
}

func pruneRefusals(records map[string]sweepLeaseRefusalRecord, nowUnixNano int64) {
	for executionID, record := range records {
		if record.RetainUntilUnixNano <= nowUnixNano {
			delete(records, executionID)
		}
	}
}

// MarkRefused persists refusal for the slot executionID of groupID, then marks
// the slot executed, when that slot is still on the installed lease. The
// refusal is written first: a crash between the two re-runs the slot, which
// refuses it again under the same execution id.
func (s *sweepLeaseStore) MarkRefused(groupID string, executionID string, collectionExpiresUnixNano int64, refusal *proto.SweepLeaseSlotRefusal, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if sweepLeaseSlot(s.leases[groupID], executionID) == nil {
		return nil
	}

	encoded, err := goproto.Marshal(refusal)
	if err != nil {
		return fmt.Errorf("encode sweep lease refusal: %w", err)
	}

	records := maps.Clone(s.refusals[groupID])
	if records == nil {
		records = make(map[string]sweepLeaseRefusalRecord)
	}

	pruneRefusals(records, now.UnixNano())
	records[executionID] = sweepLeaseRefusalRecord{
		RetainUntilUnixNano: collectionExpiresUnixNano + sweepLeaseRefusalRetention.Nanoseconds(),
		Refusal:             encoded,
	}

	data, err := json.Marshal(records)
	if err != nil {
		return fmt.Errorf("encode sweep lease refusals: %w", err)
	}

	if err := durablefs.WriteFile(s.refusalsPath(groupID), data, sweepLeaseFileMode); err != nil {
		return err
	}
	s.refusals[groupID] = records

	return s.markExecutedLocked(groupID, executionID, collectionExpiresUnixNano, now)
}

// Refusals returns every refusal the store still holds, oldest first.
func (s *sweepLeaseStore) Refusals(now time.Time) []*proto.SweepLeaseSlotRefusal {
	s.mu.Lock()
	defer s.mu.Unlock()

	var held []*proto.SweepLeaseSlotRefusal

	for _, records := range s.refusals {
		for _, record := range records {
			if record.RetainUntilUnixNano <= now.UnixNano() {
				continue
			}

			refusal := &proto.SweepLeaseSlotRefusal{}
			if err := goproto.Unmarshal(record.Refusal, refusal); err != nil {
				continue
			}
			held = append(held, refusal)
		}
	}

	sort.Slice(held, func(i, j int) bool {
		return held[i].GetRefusedAtUnixNano() < held[j].GetRefusedAtUnixNano()
	})

	return held
}

// forgetRefusalsLocked drops groupID's refusals with its lease. Core records
// a refusal only for the current lease, so none outlives it.
func (s *sweepLeaseStore) forgetRefusalsLocked(groupID string) error {
	delete(s.refusals, groupID)

	if err := os.Remove(s.refusalsPath(groupID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove sweep lease refusals: %w", err)
	}

	return nil
}

// sendSweepLeaseSlotRefusal reports refusal on sender. A missing or closed
// stream is not an error: the refusal is persisted and re-sent on connect.
func (p *PushLoop) sendSweepLeaseSlotRefusal(sender *controlStreamSender, refusal *proto.SweepLeaseSlotRefusal) {
	if sender == nil {
		return
	}

	if err := sender.Send(&proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_SweepLeaseSlotRefusal{SweepLeaseSlotRefusal: refusal},
	}); err != nil {
		p.logger.Warn().
			Err(err).
			Str("sweep_group_id", refusal.GetSweepGroupId()).
			Msg("Failed to send sweep lease slot refusal; it is re-sent on reconnect")
	}
}

// resendSweepLeaseSlotRefusals re-sends every held refusal on a new control
// stream.
func (p *PushLoop) resendSweepLeaseSlotRefusals(sender *controlStreamSender) {
	store := p.loadedSweepLeaseStore()
	if store == nil {
		return
	}

	for _, refusal := range store.Refusals(time.Now()) {
		p.sendSweepLeaseSlotRefusal(sender, refusal)
	}
}

// noteUnavailableChecks records the capability markers a refusal names before
// the refusal is reported, so the agent's capabilities already carry them.
// It reports whether that changed the agent's capabilities.
func (p *PushLoop) noteUnavailableChecks(markers []string) bool {
	if p == nil || p.server == nil || !slices.Contains(markers, capabilityTCPSynIPv6Unavailable) {
		return false
	}

	return !p.server.tcpSynIPv6Unavailable.Swap(true)
}

// reportSweepLeaseSlotRefusal sends a fresh hello first when the refusal
// changed the agent's capabilities, then the refusal, on the live stream.
func (p *PushLoop) reportSweepLeaseSlotRefusal(refusal *proto.SweepLeaseSlotRefusal, capabilitiesChanged bool) {
	p.controlSenderMu.Lock()
	sender := p.controlSender
	p.controlSenderMu.Unlock()

	if sender == nil {
		return
	}

	if capabilitiesChanged {
		if err := p.sendControlHello(sender); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to report changed capabilities before a sweep slot refusal")
		}
	}

	p.sendSweepLeaseSlotRefusal(sender, refusal)
}

// sweepSlotRefusalReporter sends a refusal to core; capabilitiesChanged says
// the refusal's markers were just added to the agent's capabilities.
type sweepSlotRefusalReporter func(refusal *proto.SweepLeaseSlotRefusal, capabilitiesChanged bool)

// preflightSlot refuses a slot before it runs when its carried set is not one
// the scanner can express. The ICMP-unavailable marker is unioned with the
// planned-run mode markers by the leased run itself, which refuses once before
// claim. A slot without a usable carried set is an error that is not a
// refusal; install validation already rules it out.
func (e *sweepLeaseExecutor) preflightSlot(lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1) error {
	_, err := sweepPlanChecks(lease, slot)
	if errors.Is(err, edgerecord.ErrSweepCheckSetUnsupported) {
		return refuseUnsupportedPlan(err)
	}
	return err
}

// refuse records the markers first, so the agent's capabilities carry them,
// then persists the refusal with the slot's executed mark and reports it.
func (e *sweepLeaseExecutor) refuse(groupID string, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, executionID string, refusal *sweepSlotRefusal, now time.Time) {
	changed := e.noteUnavailable != nil && e.noteUnavailable(refusal.markers)

	report := &proto.SweepLeaseSlotRefusal{
		SweepGroupId:            groupID,
		LeaseId:                 lease.GetLeaseId(),
		ExecutionId:             slot.GetExecutionId(),
		Reason:                  refusal.reason,
		UnavailableCapabilities: refusal.markers,
		Detail:                  refusal.detail,
		RefusedAtUnixNano:       now.UnixNano(),
	}

	if err := e.store.MarkRefused(groupID, executionID, slot.GetCollectionExpiresUnixNano(), report, now); err != nil {
		e.logger.Warn().Err(err).
			Str("sweep_group_id", groupID).
			Str("execution_id", executionID).
			Msg("Failed to persist leased slot refusal; the slot may be refused again after a restart")
	}

	e.logger.Warn().
		Str("sweep_group_id", groupID).
		Str("execution_id", executionID).
		Str("reason", refusal.reason.String()).
		Strs("unavailable_capabilities", refusal.markers).
		Str("detail", refusal.detail).
		Msg("Refused leased sweep slot")

	if e.reportRefusal != nil {
		e.reportRefusal(report, changed)
	}
}
