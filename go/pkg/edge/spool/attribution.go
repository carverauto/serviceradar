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

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

const (
	attributionFile    = "lane.attribution"
	relocationFile     = "lane.relocation"
	evidenceFormatFile = "evidence-format"
	evidenceFormatV2   = "serviceradar.spool.evidence.v2\n"
	attributionMagic   = 0x53524154
	relocationMagic    = 0x5352524c
	sidecarSlotSize    = 1024
	sidecarHeaderSize  = 29
	sidecarPayloadMax  = sidecarSlotSize - sidecarHeaderSize - sha256.Size
)

var ErrAttributionRequired = fmt.Errorf("%w: validated attribution is required", ErrPermanent)
var ErrCommittedAttribution = errors.New("spool: no sender-visible committed attribution")

// AttributedAppend carries only a typed validator's sealed result and the exact
// record bytes it approved. Attribution is derived from that result, never from a
// second caller-owned tuple. A receipt binding, if supplied, keeps its existing
// independent owner and restart inspector.
type AttributedAppend struct {
	EventID       []byte
	Body          []byte
	Validated     edgerecord.ValidatedAttribution
	ReceiptSHA256 []byte
}

// WithAttribution enables owned, durable attribution for a generation whose
// identity file already exists. It must be installed on every reopen. New empty
// generations use evidence v2; existing v1 generations remain readable and must
// rotate before accepting attributed appends. WithBindings still owns receipts;
// its attribution verdict is not consulted in this mode.
func WithAttribution(id GenerationIdentity) Option {
	return func(s *Spool) { c := id.clone(); s.attributionIdentity = &c }
}

func (s *Spool) initAttribution() error {
	s.evidenceVersion = evidenceVersion
	marker, err := os.ReadFile(filepath.Join(s.dir, evidenceFormatFile))
	if err == nil {
		if string(marker) != evidenceFormatV2 {
			return ErrCorruptGeneration
		}
		s.evidenceVersion = evidenceVersion2
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if s.attributionIdentity == nil {
		if s.evidenceVersion == evidenceVersion2 {
			return ErrAttributionRequired
		}
		return nil
	}
	raw, err := os.ReadFile(filepath.Join(s.dir, identityFile))
	if err != nil {
		return fmt.Errorf("%w: attribution identity: %w", ErrCorruptGeneration, err)
	}
	id, err := decodeIdentity(raw)
	if err != nil || !bytes.Equal(encodeIdentity(id), encodeIdentity(*s.attributionIdentity)) {
		return ErrCorruptGeneration
	}
	if s.evidenceVersion == evidenceVersion2 {
		return nil
	}
	// No existing allocation may change its evidence width. A missing record file
	// alone does not establish emptiness: either surviving evidence copy prevents it.
	if s.baseSeq != 0 {
		return nil
	}
	for _, path := range []string{s.segmentPath(), s.evidencePath(copyA), s.evidencePath(copyB)} {
		info, err := os.Stat(path)
		if err == nil && info.Size() != 0 {
			return nil
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := durablefs.WriteFile(filepath.Join(s.dir, evidenceFormatFile), []byte(evidenceFormatV2), filePerm); err != nil {
		return err
	}
	s.evidenceVersion = evidenceVersion2
	return nil
}

func bindingCoordinates(id GenerationIdentity, seq uint64, eventID, recordHash []byte) edgerecord.LocalBindingCoordinates {
	return edgerecord.LocalBindingCoordinates{
		NetworkScopeID: id.Identity.NetworkScopeID, AuthenticatedAgentID: id.Identity.AgentID,
		LaneRouteProfile: id.Lane.RouteProfile, LaneTrafficClass: id.Lane.TrafficClass,
		SpoolGenerationID: id.SpoolID, Sequence: seq, EventID: eventID, RecordSHA256: recordHash,
	}
}

func appendCoordinates(key LaneKey, identity Identity, eventID, body []byte) edgerecord.LocalBindingCoordinates {
	hash := sha256.Sum256(body)
	return bindingCoordinates(GenerationIdentity{Lane: key, Identity: identity}, 0, eventID, hash[:])
}

func attributionSpan(seq uint64, a edgerecord.RecoveryAttribution) *edgev1.EdgeClassificationSpanV1 {
	span := &edgev1.EdgeClassificationSpanV1{FromSequence: seq, ThroughSequence: seq}
	if a.Active {
		span.Classification = &edgev1.EdgeClassificationSpanV1_AttributedActive{AttributedActive: &edgev1.EdgeAttributedActiveV1{Identity: a.Identity, RangeSha256: a.RangeSHA256}}
	} else {
		span.Classification = &edgev1.EdgeClassificationSpanV1_AttributedPassive{AttributedPassive: &edgev1.EdgeAttributedPassiveV1{Identity: a.Identity}}
	}
	return span
}

func spanAttribution(span *edgev1.EdgeClassificationSpanV1) (edgerecord.RecoveryAttribution, error) {
	if err := edgerecord.ValidateClassificationSpan(span); err != nil {
		return edgerecord.RecoveryAttribution{}, err
	}
	if a := span.GetAttributedActive(); a != nil {
		return edgerecord.RecoveryAttribution{Active: true, Identity: a.Identity, RangeSHA256: a.RangeSha256}, nil
	}
	if a := span.GetAttributedPassive(); a != nil {
		return edgerecord.RecoveryAttribution{Identity: a.Identity}, nil
	}
	return edgerecord.RecoveryAttribution{}, ErrCommittedAttribution
}

type attributionEntry struct {
	coordinates edgerecord.LocalBindingCoordinates
	attribution edgerecord.RecoveryAttribution
	digest      []byte
}

// This key is only for bounded segment accounting, never evidence or a wire
// digest. Normalize the interval so physical slot coordinates cannot split one
// unchanged attribution body into a distinct key at every append.
func attributionAccountingKey(a edgerecord.RecoveryAttribution) []byte {
	raw, _ := proto.MarshalOptions{Deterministic: true}.Marshal(attributionSpan(1, a))
	hash := sha256.Sum256(raw)
	return hash[:]
}

func encodeAttributionEntry(entry attributionEntry) ([]byte, error) {
	span, err := proto.MarshalOptions{Deterministic: true}.Marshal(attributionSpan(entry.coordinates.Sequence, entry.attribution))
	if err != nil {
		return nil, err
	}
	payload := append(bytes.Clone(entry.coordinates.EventID), entry.coordinates.RecordSHA256...)
	payload = append(payload, entry.digest...)
	payload = append(payload, span...)
	return encodeSidecar(attributionMagic, edgerecord.LocalBindingVersion, entry.coordinates.Sequence, payload)
}

// Fixed positions let an unreadable entry retain its slot identity even if its
// neighbours are corrupt. The complete frozen span and a relocation map each fit
// well below the 963-byte payload bound. Padding is checksummed, never hashed as
// part of local_binding.v1.
func encodeSidecar(magic uint32, version, seq uint64, payload []byte) ([]byte, error) {
	if len(payload) > sidecarPayloadMax {
		return nil, fmt.Errorf("%w: sidecar payload too large", ErrPermanent)
	}
	b := make([]byte, sidecarSlotSize)
	binary.BigEndian.PutUint32(b, magic)
	b[4] = 1
	binary.BigEndian.PutUint64(b[5:], version)
	binary.BigEndian.PutUint64(b[13:], seq)
	binary.BigEndian.PutUint32(b[21:], uint32(len(payload)))
	binary.BigEndian.PutUint32(b[25:], crc32.Checksum(b[:25], crcTable))
	copy(b[sidecarHeaderSize:], payload)
	h := sha256.Sum256(b[:sidecarSlotSize-sha256.Size])
	copy(b[sidecarSlotSize-sha256.Size:], h[:])
	return b, nil
}

func decodeSidecar(b []byte, magic uint32, seq uint64) ([]byte, AttributionState) {
	if len(b) == 0 || allZero(b) {
		return nil, AttributionAbsent
	}
	if len(b) < sidecarHeaderSize || binary.BigEndian.Uint32(b) != magic || b[4] != 1 ||
		binary.BigEndian.Uint64(b[13:]) != seq || binary.BigEndian.Uint32(b[25:]) != crc32.Checksum(b[:25], crcTable) {
		return nil, AttributionNotVerifying
	}
	// Fail closed before parsing or hashing a version this reader does not own.
	if binary.BigEndian.Uint64(b[5:]) != edgerecord.LocalBindingVersion {
		return nil, AttributionVersionUnsupported
	}
	if len(b) != sidecarSlotSize {
		return nil, AttributionNotVerifying
	}
	n := int(binary.BigEndian.Uint32(b[21:]))
	if n > sidecarPayloadMax {
		return nil, AttributionNotVerifying
	}
	h := sha256.Sum256(b[:sidecarSlotSize-sha256.Size])
	if !bytes.Equal(h[:], b[sidecarSlotSize-sha256.Size:]) || !allZero(b[sidecarHeaderSize+n:sidecarSlotSize-sha256.Size]) {
		return nil, AttributionNotVerifying
	}
	return b[sidecarHeaderSize : sidecarHeaderSize+n], AttributionVerifies
}

func (s *Spool) readSidecar(name string, magic uint32, seq uint64) ([]byte, AttributionState, error) {
	if seq <= s.baseSeq {
		return nil, AttributionAbsent, nil
	}
	f, err := os.Open(filepath.Join(s.dataDir, name))
	if errors.Is(err, os.ErrNotExist) {
		return nil, AttributionAbsent, nil
	}
	if err != nil {
		return nil, AttributionNotVerifying, err
	}
	defer func() { _ = f.Close() }()
	b := make([]byte, sidecarSlotSize)
	n, err := f.ReadAt(b, int64(seq-s.baseSeq-1)*sidecarSlotSize)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, AttributionNotVerifying, err
	}
	payload, state := decodeSidecar(b[:n], magic, seq)
	return payload, state, nil
}

func (s *Spool) inspectAttribution(ev SlotEvidence) (attributionEntry, AttributionVerdict, error) {
	payload, state, err := s.readSidecar(attributionFile, attributionMagic, ev.Sequence)
	if err != nil {
		return attributionEntry{}, AttributionVerdict{}, err
	}
	bad := AttributionVerdict{State: state}
	if state != AttributionVerifies {
		return attributionEntry{}, bad, nil
	}
	bad.State = AttributionNotVerifying
	if len(payload) < 80 || len(ev.EventID) != 16 || len(ev.RecordSHA256) != 32 ||
		!bytes.Equal(payload[:16], ev.EventID) || !bytes.Equal(payload[16:48], ev.RecordSHA256) {
		return attributionEntry{}, bad, nil
	}
	var span edgev1.EdgeClassificationSpanV1
	if proto.Unmarshal(payload[80:], &span) != nil || span.GetFromSequence() != ev.Sequence || span.GetThroughSequence() != ev.Sequence {
		return attributionEntry{}, bad, nil
	}
	a, err := spanAttribution(&span)
	if err != nil {
		return attributionEntry{}, bad, nil
	}
	c := bindingCoordinates(*s.attributionIdentity, ev.Sequence, payload[:16], payload[16:48])
	digest, err := edgerecord.LocalBindingDigest(edgerecord.LocalBindingVersion, c, a)
	if err != nil || !bytes.Equal(digest, payload[48:80]) {
		return attributionEntry{}, bad, nil
	}
	return attributionEntry{coordinates: c, attribution: a, digest: digest}, AttributionVerdict{State: AttributionVerifies, Representable: true, Digest: digest, Classification: &span, accountingKey: attributionAccountingKey(a)}, nil
}

func (s *Spool) sidecarGrowth(name string, seq uint64) (uint64, error) {
	end := int64(seq-s.baseSeq) * sidecarSlotSize
	info, err := os.Stat(filepath.Join(s.dataDir, name))
	if errors.Is(err, os.ErrNotExist) {
		return uint64(end), nil
	}
	if err != nil {
		return 0, err
	}
	return uint64(max(end-info.Size(), 0)), nil
}

func (s *Spool) sidecarHighWater() (uint64, error) {
	high := s.baseSeq
	if s.attributionIdentity == nil {
		return high, nil
	}
	for _, name := range []string{attributionFile, relocationFile} {
		info, err := os.Stat(filepath.Join(s.dataDir, name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return 0, err
		}
		high = max(high, s.baseSeq+uint64((info.Size()+sidecarSlotSize-1)/sidecarSlotSize))
	}
	return high, nil
}

func (s *Spool) writeSidecar(name string, seq uint64, raw []byte, contentBarrier, dirBarrier barrier) error {
	path := filepath.Join(s.dataDir, name)
	if err := s.cross(contentBarrier); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, filePerm)
	if err != nil {
		return &FailStopError{Op: "create", Path: path, Err: err}
	}
	_, err = f.WriteAt(raw, int64(seq-s.baseSeq-1)*sidecarSlotSize)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return &FailStopError{Op: "write attribution", Path: path, Err: err}
	}
	if err := s.cross(dirBarrier); err != nil {
		return err
	}
	return fsyncDir(s.dataDir)
}
