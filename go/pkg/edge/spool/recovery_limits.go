// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"errors"
	"fmt"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// requireRelocatableAppend bounds one attributed generation by the reserved
// capacity for its complete destination. This is a physical segment bound,
// independent of attribution cardinality and manifest coarsening. The caller
// holds s.mu; no allocation or write has happened yet.
func (s *Spool) requireRelocatableAppend(bodyLen int) error {
	if s.attributionIdentity == nil {
		return nil
	}
	if s.alloc == nil {
		return fmt.Errorf("%w: attributed generations require a shared recovery allocator", errors.Join(ErrAdmissionRefused, ErrInvalidAllocatorConfig))
	}
	// nextSeq-baseSeq includes the proposed append. Existing drained layouts
	// retain monotonic sequences but start their physical slot indexing at baseSeq.
	slots := s.nextSeq - s.baseSeq
	recordBytes := uint64(minRecordLen + bodyLen)
	const evidenceAndTerminal = 4*evidenceEntryLen2 + terminalEvidenceAllowance
	const sidecars = 2 * sidecarSlotSize
	destinationBudget := s.alloc.budgets[ArtifactDestinationSegment]
	sidecarBudget := s.alloc.budgets[ArtifactAttributionSidecar]
	// A record that cannot fit an empty generation cannot be repaired by rotation.
	if recordBytes > destinationBudget || evidenceAndTerminal > destinationBudget-recordBytes || sidecars > sidecarBudget {
		return fmt.Errorf("%w: single record exceeds complete relocation footprint", errors.Join(ErrAdmissionRefused, ErrInvalidAllocatorConfig))
	}
	if slots > edgerecord.MaxRecoverySlots || slots > sidecarBudget/sidecars {
		return rotationRefusal("recovery sidecars or allocated slots", s.segBounds.stats())
	}
	// Subtraction avoids overflow in segment bytes + record + per-slot evidence.
	remaining := destinationBudget - recordBytes
	if uint64(s.segSize) > remaining || slots > (remaining-uint64(s.segSize))/evidenceAndTerminal {
		return rotationRefusal("complete recovery destination bytes", s.segBounds.stats())
	}
	return nil
}
