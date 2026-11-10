// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// RecoveryManifest contains exact frozen publication bodies. It is not a PubAck or a
// consumer completion. The coordinator still needs gateway-issued capabilities.
type RecoveryManifest struct {
	Pages     [][]byte
	Tombstone []byte
}

func constructRecoveryManifest(p RecoveryPlan) (RecoveryManifest, error) {
	spans := coarsenRecoverySlots(p.Slots)
	count := (len(spans) + edgerecord.MaxSpansPerPage - 1) / edgerecord.MaxSpansPerPage
	recoveryPages := make([]*edgev1.EdgeLossManifestPageV1, 0, count)
	result := RecoveryManifest{Pages: make([][]byte, 0, count)}
	var previous []byte
	for start := 0; start < len(spans); start += edgerecord.MaxSpansPerPage {
		end := min(start+edgerecord.MaxSpansPerPage, len(spans))
		page := &edgev1.EdgeLossManifestPageV1{
			RecoveryId: p.RecoveryID, DigestVersion: edgerecord.RecoveryDigestVersion,
			PageIndex: uint32(len(recoveryPages)), PageCount: uint32(count),
			Terminal: end == len(spans), PrevPageSha256: previous,
			ClassificationSpans: spans[start:end],
		}
		page.PageSha256 = edgerecord.ManifestPageDigest(page)
		raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(page)
		if err != nil {
			return RecoveryManifest{}, err
		}
		result.Pages = append(result.Pages, raw)
		recoveryPages = append(recoveryPages, page)
		previous = page.PageSha256
	}
	root := edgerecord.ManifestRoot(recoveryPages)
	if err := edgerecord.ValidateManifestChainFromRaw(result.Pages, root); err != nil {
		return RecoveryManifest{}, err
	}
	tombstone := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: p.RecoveryID, PriorSpoolId: p.Source.SpoolID, NewSpoolId: p.NewSpoolID,
		ManifestRootSha256: root, ManifestPageCount: uint32(len(recoveryPages)),
		DigestVersion:      edgerecord.RecoveryDigestVersion,
		DetectedAtUnixNano: p.DetectedAtUnixNano, Reason: p.Reason,
	}
	if err := edgerecord.ValidateTombstone(tombstone, recoveryPages); err != nil {
		return RecoveryManifest{}, err
	}
	var err error
	result.Tombstone, err = proto.MarshalOptions{Deterministic: true}.Marshal(tombstone)
	return result, err
}

// Coarsening walks the full allocated interval, not a final-page approximation.
// A preserved slot interrupts adjacency even when the losses around it match.
func coarsenRecoverySlots(slots []RecoverySlot) []*edgev1.EdgeClassificationSpanV1 {
	var spans []*edgev1.EdgeClassificationSpanV1
	for _, slot := range slots {
		if slot.Loss == nil {
			continue
		}
		next := proto.Clone(slot.Loss).(*edgev1.EdgeClassificationSpanV1)
		if len(spans) != 0 {
			previous := spans[len(spans)-1]
			if previous.GetThroughSequence() == slot.Sequence-1 && equalRecoveryClassification(previous, next) {
				previous.ThroughSequence = slot.Sequence
				continue
			}
		}
		spans = append(spans, next)
	}
	return spans
}

func equalRecoveryClassification(a, b *edgev1.EdgeClassificationSpanV1) bool {
	// Both spans were validated before journalling. Comparing the complete
	// message with just its interval normalized includes every oneof member.
	copy := proto.Clone(b).(*edgev1.EdgeClassificationSpanV1)
	copy.FromSequence, copy.ThroughSequence = a.FromSequence, a.ThroughSequence
	return proto.Equal(a, copy)
}

func equalRecoveryManifest(a, b RecoveryManifest) bool {
	if len(a.Pages) != len(b.Pages) || !bytes.Equal(a.Tombstone, b.Tombstone) {
		return false
	}
	for i := range a.Pages {
		if !bytes.Equal(a.Pages[i], b.Pages[i]) {
			return false
		}
	}
	return true
}
