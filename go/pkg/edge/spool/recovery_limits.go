// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"math/bits"

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
		return fmt.Errorf("%w: attributed generations require a shared recovery allocator", errors.Join(ErrRetryable, ErrAdmissionRefused, ErrInvalidAllocatorConfig))
	}
	// nextSeq-baseSeq includes the proposed append. Existing drained layouts
	// retain monotonic sequences but start their physical slot indexing at baseSeq.
	slots := s.nextSeq - s.baseSeq
	recordBytes := uint64(minRecordLen + bodyLen)
	const evidenceAndTerminal = 4*evidenceEntryLen2 + terminalEvidenceAllowance
	const sidecars = 2 * sidecarSlotSize
	destinationBudget := s.alloc.budgets[ArtifactDestinationSegment]
	if destinationBudget < recoveryGenerationFixedBytes {
		return fmt.Errorf("%w: generation metadata exceeds relocation footprint", errors.Join(ErrRetryable, ErrAdmissionRefused, ErrInvalidAllocatorConfig))
	}
	destinationBudget -= recoveryGenerationFixedBytes
	sidecarBudget := s.alloc.budgets[ArtifactAttributionSidecar]
	// A record that cannot fit an empty generation cannot be repaired by rotation.
	if recordBytes > destinationBudget || evidenceAndTerminal > destinationBudget-recordBytes || sidecars > sidecarBudget {
		return fmt.Errorf("%w: single record exceeds complete relocation footprint", errors.Join(ErrRetryable, ErrAdmissionRefused, ErrInvalidAllocatorConfig))
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

const (
	// MaxRecoveryPublicationBytes bounds the aggregate exact encoded control
	// records frozen before any attempt is appended, independently of page bytes.
	MaxRecoveryPublicationBytes = 512 << 10
	// MaxRecoveryControlAttempts bounds both authority refresh and torn-append replay.
	MaxRecoveryControlAttempts = 2
	// MaxRecoveryPhaseBytes bounds all immutable phase records for one copy.
	MaxRecoveryPhaseBytes = 2 << 20
	// Non-bundle, non-coverage phase bodies are bounded separately so admitting
	// both maximum bundles still leaves room for attempts, receipts and completion.
	maxRecoveryMetadataPhaseBytes     = 16 << 10
	maxFrozenRecoveryAttributionBytes = sidecarPayloadMax - 16 - 2*sha256.Size
	// JSON byte slices use base64; every record can add two padding input bytes.
	maxRecoveryPublicationBundleBytes = 2 + maxRecoveryPublications*(len(`{"EventID":"","Body":"","Attribution":""}`)+1+24+4*((maxFrozenRecoveryAttributionBytes+2)/3)) + 4*((MaxRecoveryPublicationBytes+2*maxRecoveryPublications)/3)
	maxRecoveryCoverageBytes          = recoveryCoverageHeader + edgerecord.MaxRecoverySlots*(1+8+8+16+4*32+8)
	recoveryPhaseWorstCaseBytes       = MaxRecoveryControlAttempts*(maxRecoveryPublicationBundleBytes+recoveryPhaseOverhead) + (MaxRecoveryControlAttempts+maxRecoveryPublications+4)*(maxRecoveryMetadataPhaseBytes+recoveryPhaseOverhead) + maxRecoveryCoverageBytes + recoveryPhaseOverhead
	// This covers frozen identity (including max principal), evidence format,
	// dedicated generation marker, closed marker and the fixed recovery hold.
	recoveryGenerationFixedBytes = 1024
	maxRecoveryPublications      = (edgerecord.MaxRecoverySlots+edgerecord.MaxSpansPerPage-1)/edgerecord.MaxSpansPerPage + 1
	recoveryControlAttemptBytes  = MaxRecoveryPublicationBytes + maxRecoveryPublications*(minRecordLen+4*evidenceEntryLen2+sidecarSlotSize+terminalEvidenceAllowance) + recoveryGenerationFixedBytes
)

// DefaultRecoveryFootprint leaves room for a full bounded source generation,
// both journals and their phase/repair writes, two full control attempts,
// retained coverage evidence, and filesystem metadata. Total: 47 MiB per grant.
func DefaultRecoveryFootprint() Footprint {
	return Footprint{DestinationSegment: 8 << 20, AttributionSidecar: 2 << 20, JournalCopy: 2 * (MaxRecoveryJournalBytes + MaxRecoveryPhaseBytes), ManifestPages: 3 << 20, Mapping: 21 << 20, FilesystemMetadata: 1 << 20}
}

// ValidateCoordinator refuses configurations that cannot preserve even the
// largest supported EdgeRecord and complete the bounded recovery protocol.
// NewAllocator still supports smaller footprints for ordinary reclaim users.
func (f Footprint) ValidateCoordinator() error {
	source, carry := bits.Add64(f.DestinationSegment, f.AttributionSidecar, 0)
	hi, archives := bits.Mul64(source, 2)
	archives, extra := bits.Add64(archives, 1<<20, 0)
	if carry|hi|extra != 0 {
		return fmt.Errorf("%w: archive bound overflow", ErrInvalidAllocatorConfig)
	}
	minima := Footprint{
		DestinationSegment: edgerecord.MaxRecordBytes + minRecordLen + 4*evidenceEntryLen2 + terminalEvidenceAllowance + recoveryGenerationFixedBytes,
		AttributionSidecar: 2 * sidecarSlotSize,
		JournalCopy:        2 * (MaxRecoveryJournalBytes + MaxRecoveryPhaseBytes),
		ManifestPages:      2*MaxRecoveryControlAttempts*recoveryControlAttemptBytes + (64 << 10),
		Mapping:            archives, FilesystemMetadata: 1 << 20,
	}.budgets()
	for art, n := range f.budgets() {
		if n < minima[art] {
			return fmt.Errorf("%w: %s requires at least %d bytes for recovery coordinator", ErrInvalidAllocatorConfig, Artifact(art), minima[art])
		}
	}
	_, err := f.PerRecovery()
	return err
}
