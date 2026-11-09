// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

// Package recovery freezes bounded agent recovery evidence and constructs loss
// manifests. It does not sign records, claim copy completion, authorize source
// deletion, or garbage-collect recovery evidence.
package recovery

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

var (
	ErrPlan          = errors.New("recovery: invalid frozen plan")
	ErrNoLoss        = errors.New("recovery: copies-only compaction requires a separate path")
	ErrSplitRequired = errors.New("recovery: partition the selected interval before freezing")
)

// Plan describes every allocated slot in one selected interval of a frozen
// generation. ReclaimThrough and HighWater belong to the entire source; First
// and Last select this bounded recovery. Other intervals require other IDs.
type Plan struct {
	RecoveryID         []byte
	DetectedAtUnixNano int64
	Reason             string
	Source             spool.GenerationIdentity
	NewSpoolID         []byte
	ReclaimThrough     uint64
	HighWater          uint64
	First              uint64
	Last               uint64
	Slots              []Slot
}

// CopyIntent records where a preserved record is to be committed. These hashes
// and coordinates are intent, never proof of destination durability or coverage.
type CopyIntent struct {
	NewSequence              uint64
	EventID                  []byte
	RecordSHA256             []byte
	SourceBindingSHA256      []byte
	AttributionBindingSHA256 []byte
}

// Slot holds exactly one singleton loss body or one intended preserved copy.
// Loss bodies remain per-sequence even when the emitted manifest coarsens them.
type Slot struct {
	Sequence uint64
	Loss     *edgev1.EdgeClassificationSpanV1
	Copy     *CopyIntent
}

// slotEncoding keeps the complete protobuf body as bytes rather than relying on
// encoding/json to reconstruct a generated Go oneof interface.
type slotEncoding struct {
	Sequence uint64
	Loss     []byte
	Copy     *CopyIntent
}

func (s Slot) MarshalJSON() ([]byte, error) {
	w := slotEncoding{Sequence: s.Sequence, Copy: s.Copy}
	if s.Loss != nil {
		var err error
		w.Loss, err = proto.MarshalOptions{Deterministic: true}.Marshal(s.Loss)
		if err != nil {
			return nil, err
		}
	}
	return json.Marshal(w)
}

func (s *Slot) UnmarshalJSON(raw []byte) error {
	var w slotEncoding
	if err := decodeJSON(raw, &w); err != nil {
		return err
	}
	*s = Slot{Sequence: w.Sequence, Copy: w.Copy}
	if len(w.Loss) != 0 {
		s.Loss = new(edgev1.EdgeClassificationSpanV1)
		return proto.Unmarshal(w.Loss, s.Loss)
	}
	return nil
}

func decodeJSON(raw []byte, target any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("%w: trailing journal data", ErrPlan)
	}
	return nil
}

func validatePlan(p Plan) error {
	if p.DetectedAtUnixNano <= 0 || len(p.Reason) == 0 || len(p.Reason) > edgerecord.MaxReasonBytes || !utf8.ValidString(p.Reason) {
		return fmt.Errorf("%w: tombstone detection evidence", ErrPlan)
	}
	if len(p.Slots) > edgerecord.MaxRecoverySlots || (p.Last >= p.First && p.Last-p.First >= edgerecord.MaxRecoverySlots) {
		return ErrSplitRequired
	}
	if len(p.Slots) == 0 ||
		p.First == 0 || p.First <= p.ReclaimThrough || p.Last < p.First ||
		p.Last > p.HighWater ||
		uint64(len(p.Slots)) != p.Last-p.First+1 {
		return fmt.Errorf("%w: selected allocated interval", ErrPlan)
	}
	for _, id := range [][]byte{p.RecoveryID, p.Source.SpoolID, p.NewSpoolID} {
		if edgerecord.ValidateUUIDv7(id) != nil {
			return fmt.Errorf("%w: generation or recovery id", ErrPlan)
		}
	}
	if bytes.Equal(p.Source.SpoolID, p.NewSpoolID) || p.Source.Ordinal == 0 || !p.Source.Lane.Valid() ||
		edgerecord.ValidateCanonicalUUID(p.Source.Identity.NetworkScopeID) != nil ||
		edgerecord.ValidateAuthenticatedPrincipal(p.Source.Identity.AgentID) != nil {
		return fmt.Errorf("%w: frozen identity", ErrPlan)
	}
	destinations := make(map[uint64]bool)
	losses := 0
	for i, slot := range p.Slots {
		if slot.Sequence != p.First+uint64(i) || (slot.Loss == nil) == (slot.Copy == nil) {
			return fmt.Errorf("%w: sequence %d must have exactly one classification", ErrPlan, slot.Sequence)
		}
		if slot.Loss != nil {
			if slot.Loss.GetFromSequence() != slot.Sequence || slot.Loss.GetThroughSequence() != slot.Sequence {
				return fmt.Errorf("%w: loss evidence must be per-sequence", ErrPlan)
			}
			if err := edgerecord.ValidateClassificationSpan(slot.Loss); err != nil {
				return err
			}
			losses++
			continue
		}
		if err := validateCopy(slot.Copy); err != nil {
			return err
		}
		if destinations[slot.Copy.NewSequence] {
			return fmt.Errorf("%w: duplicate destination", ErrPlan)
		}
		destinations[slot.Copy.NewSequence] = true
	}
	if losses == 0 {
		return ErrNoLoss
	}
	return nil
}

func validateCopy(c *CopyIntent) error {
	if c.NewSequence == 0 || edgerecord.ValidateUUIDv7(c.EventID) != nil {
		return fmt.Errorf("%w: copy identity", ErrPlan)
	}
	for _, digest := range [][]byte{c.RecordSHA256, c.SourceBindingSHA256, c.AttributionBindingSHA256} {
		if len(digest) != sha256.Size {
			return fmt.Errorf("%w: copy evidence digest", ErrPlan)
		}
	}
	return nil
}
