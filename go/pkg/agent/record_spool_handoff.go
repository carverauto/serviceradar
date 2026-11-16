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
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Upgrade-time handoff (design Decision 8). New code cannot reach an installed
// old updater or old agent, so the new agent drains whatever an older layout left
// behind on its own: every committed record above the layout's resolved watermark
// goes, in order, through late admission (or, if permanently invalid, rejection
// evidence), the layout records that custody moved, and once nothing remains it is
// retired by the structural emptiness proof RetireDrainedLegacyFlat already uses.
// Only bytes the agent cannot parse as a known layout stay retained and flagged.

// LegacyHandoff reports one handoff pass over the pre-lane flat spool.
type LegacyHandoff struct {
	// HandedOff counts records admitted late this pass; Rejected counts records
	// kept as rejection evidence this pass.
	HandedOff, Rejected int
	// Pending is how many committed records the flat spool still holds.
	Pending uint64
	// Reason is why the pass stopped with records pending (empty when none).
	Reason string
	// Retired lists what was removed once the spool was empty.
	Retired spool.LegacyFlatInventory
}

// HandOffLegacy runs one ordered handoff pass over the pre-lane flat spool. Only
// a missing trust snapshot or an UNAVAILABLE key lookup stops it (the record and
// everything after it stay put and the pass is retried); a full rejection-evidence
// store also stops it, because an invalid record is resolved only once its evidence
// is durable. Flat storage holding an entry the agent cannot account for is left
// untouched, as before.
func (s *RecordSpool) HandOffLegacy() (LegacyHandoff, error) {
	s.handoffMu.Lock()
	defer s.handoffMu.Unlock()
	inv, err := spool.InspectLegacyFlat(s.root)
	if err != nil || !inv.Present() {
		return LegacyHandoff{}, err
	}
	if len(inv.Unrecognized) > 0 {
		return LegacyHandoff{Reason: "unsupported_legacy_storage"}, spool.ErrLegacyFlatNotDrained
	}
	report := LegacyHandoff{}
	if !inv.Drained {
		if err := s.handOffFlat(&report); err != nil {
			s.recordHandoff(report)
			return report, err
		}
	}
	retired, err := spool.RetireDrainedLegacyFlat(s.root)
	if err != nil {
		report.Reason = err.Error()
		s.recordHandoff(report)
		return report, err
	}
	report.Retired = retired
	s.retireLegacyCharge()
	s.recordHandoff(report)
	return report, nil
}

func (s *RecordSpool) handOffFlat(report *LegacyHandoff) error {
	flat, err := spool.Open(s.root)
	if err != nil {
		report.Reason = err.Error()
		return fmt.Errorf("open legacy flat spool: %w", err)
	}
	defer func() { _ = flat.Close() }()
	pending, err := flat.Unresolved()
	if err != nil {
		report.Reason = err.Error()
		return err
	}
	report.Pending = uint64(len(pending))
	for i, rec := range pending {
		// Only the first record of a pass can already be in late storage: a crash
		// after its late append and before its local resolution.
		receipt, admitErr := s.admitLate(rec.Body, i == 0)
		disposition := edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
		var custody []byte
		switch {
		case admitErr == nil:
			custody = receipt.Receipt.Generation.SpoolID
		case errors.Is(admitErr, spool.ErrPermanent):
			if err := s.rejections.write(rec.EventID, rec.Body, admitErr.Error()); err != nil {
				report.Reason = err.Error()
				return err
			}
			disposition = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE
		default:
			report.Reason = admitErr.Error()
			return admitErr
		}
		if err := resolveHandedOff(flat, rec, disposition, custody); err != nil {
			report.Reason = err.Error()
			return err
		}
		if disposition == edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE {
			report.Rejected++
		} else {
			report.HandedOff++
		}
		report.Pending--
	}
	if err := flat.ReclaimResolved(); err != nil {
		report.Reason = err.Error()
		return fmt.Errorf("reclaim legacy flat spool: %w", err)
	}
	return nil
}

// resolveHandedOff persists the layout's local custody transfer for one record.
// A legacy layout is never delivered to a gateway, so its terminal evidence names
// the local owner that now holds the exact bytes: ACCEPTED_AUTHORITATIVE with the
// late generation's spool id, or ACCEPTED_QUARANTINE for rejection evidence.
func resolveHandedOff(flat *spool.Spool, rec spool.Record, kind edgev1.EdgeRecordDispositionKind, custody []byte) error {
	evidence, err := proto.MarshalOptions{Deterministic: true}.Marshal(&edgev1.EdgeDeliveryAckV1{
		SpoolId:                 custody,
		ResolvedThroughSequence: rec.Sequence,
		Dispositions:            []*edgev1.EdgeRecordDisposition{{Sequence: rec.Sequence, EventId: rec.EventID, Kind: kind}},
	})
	if err != nil {
		return err
	}
	return flat.ResolveWithEvidence(rec.Sequence, evidence)
}

// recordHandoff keeps the last pass for status reporting.
func (s *RecordSpool) recordHandoff(report LegacyHandoff) {
	s.handoffStatus.Store(&report)
}

// LegacyHandoffStatus returns the last handoff pass, if one ran.
func (s *RecordSpool) LegacyHandoffStatus() (LegacyHandoff, bool) {
	report := s.handoffStatus.Load()
	if report == nil {
		return LegacyHandoff{}, false
	}
	return *report, true
}

// retireLegacyCharge drops the retained-legacy charge once the flat storage is gone.
func (s *RecordSpool) retireLegacyCharge() {
	retained, err := retainedStorageBytes(s.root)
	if err != nil {
		return
	}
	s.allocator.ChargeMeasured(s.root, retained)
	s.legacyBytes.Store(retained)
}

// Rejection evidence for records that can never be admitted late. Entries are
// durable before the record they hold is resolved anywhere, and the store never
// evicts: when full, writing is refused (retryable) so the source keeps the record.
//
//	"SRLR0001" | u32 LE reason length | reason | record bytes | SHA-256 of everything before
const (
	rejectionEvidenceDir        = "rejected"
	rejectionEvidenceMagic      = "SRLR0001"
	rejectionEvidenceMaxRecords = 1024
	rejectionEvidenceMaxBytes   = 4 << 20
)

// ErrRejectionEvidenceFull is retryable: the evidence store is at its bound and
// keeps every entry, so the source must keep the record until room is made.
var ErrRejectionEvidenceFull = errors.New("late rejection evidence store is full")

type rejectionEvidence struct {
	dir       string
	allocator *spool.Allocator
	mu        sync.Mutex
}

func (r *rejectionEvidence) write(eventID, body []byte, reason string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := durablefs.MkdirAll(r.dir, 0o700); err != nil {
		return err
	}
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		return err
	}
	var used uint64
	for _, entry := range entries {
		info, infoErr := entry.Info()
		if infoErr != nil {
			return infoErr
		}
		used += uint64(info.Size())
	}
	sum := sha256.Sum256(body)
	name := hex.EncodeToString(eventID) + "-" + hex.EncodeToString(sum[:8]) + ".pb"
	if _, statErr := os.Stat(filepath.Join(r.dir, name)); statErr == nil {
		return nil
	}
	entry := make([]byte, 0, len(rejectionEvidenceMagic)+4+len(reason)+len(body)+sha256.Size)
	entry = append(entry, rejectionEvidenceMagic...)
	entry = binary.LittleEndian.AppendUint32(entry, uint32(len(reason)))
	entry = append(entry, reason...)
	entry = append(entry, body...)
	digest := sha256.Sum256(entry)
	entry = append(entry, digest[:]...)
	if len(entries) >= rejectionEvidenceMaxRecords || used+uint64(len(entry)) > rejectionEvidenceMaxBytes {
		return ErrRejectionEvidenceFull
	}
	if err := durablefs.WriteFile(filepath.Join(r.dir, name), entry, 0o600); err != nil {
		return err
	}
	r.allocator.ChargeMeasured(r.dir, used+uint64(len(entry)))
	return nil
}
