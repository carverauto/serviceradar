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
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Sweep schedule leases (openspec/changes/unify-sweep-results-proto, M2.0d3):
// core pushes each leased sweep group's pre-minted executions as chunked
// SweepLeaseV1 window replacements on the control stream. This file owns the
// agent side of that carrier: reassembly, install checks, the per-group
// installed lease persisted across restarts, and the SweepLeaseAck answer.
// Running the installed slots is M2.0e, in sweep_lease_executor.go; an
// installed lease there replaces the group's local ticker.

const (
	// sweepLeaseDirName is the per-group lease store under the agent runtime root.
	sweepLeaseDirName = "sweep-leases"
	// sweepLeaseVersion is the only SweepLeaseV1 lease_version this agent installs.
	sweepLeaseVersion = 1
	// maxSweepLeasePayloadBytes bounds one reassembled push, matching the
	// gateway's stream window budget for lease chunks.
	maxSweepLeasePayloadBytes = 64 << 20
	sweepLeaseFileMode        = 0o600
	sweepLeaseDirMode         = 0o700
)

var (
	errInvalidSweepLeaseChunk = errors.New("invalid sweep lease chunk")
	errInvalidSweepLease      = errors.New("invalid sweep lease")
)

// sweepLeaseAssembler collects the chunks of one lease push. The gateway
// sends a push's chunks back to back, so a chunk 0 starts a new push and
// discards any partial one, exactly like configPushAssembler.
type sweepLeaseAssembler struct {
	chunks []*proto.SweepLeaseChunk
	bytes  int
}

// add buffers chunk and returns the reassembled payload once the final chunk
// arrives, or nil while the push is incomplete. A structurally broken push
// (index, count, budget, or digest) is an error and resets the assembler.
func (a *sweepLeaseAssembler) add(chunk *proto.SweepLeaseChunk) ([]byte, error) {
	if chunk.GetChunkIndex() == 0 {
		a.chunks = a.chunks[:0]
		a.bytes = 0
	}

	if int(chunk.GetChunkIndex()) != len(a.chunks) {
		index, want := chunk.GetChunkIndex(), len(a.chunks)
		a.reset()

		return nil, fmt.Errorf("%w: chunk index %d, want %d", errInvalidSweepLeaseChunk, index, want)
	}

	a.bytes += len(chunk.GetPayload())
	if a.bytes > maxSweepLeasePayloadBytes {
		a.reset()

		return nil, fmt.Errorf("%w: push exceeds %d bytes", errInvalidSweepLeaseChunk, maxSweepLeasePayloadBytes)
	}

	a.chunks = append(a.chunks, chunk)
	if total := int(a.chunks[0].GetTotalChunks()); total <= 0 || len(a.chunks) > total {
		received := len(a.chunks)
		a.reset()

		return nil, fmt.Errorf("%w: received %d chunks for a push of %d", errInvalidSweepLeaseChunk, received, total)
	}

	if !chunk.GetIsFinal() {
		return nil, nil
	}

	chunks := a.chunks
	a.reset()

	return reassembleSweepLeaseChunks(chunks)
}

func (a *sweepLeaseAssembler) reset() {
	a.chunks = nil
	a.bytes = 0
}

// reassembleSweepLeaseChunks joins one complete push in index order and
// verifies the SHA-256 every chunk carries for the whole payload.
func reassembleSweepLeaseChunks(chunks []*proto.SweepLeaseChunk) ([]byte, error) {
	first := chunks[0]
	if int(first.GetTotalChunks()) != len(chunks) {
		return nil, fmt.Errorf("%w: final chunk at %d of %d", errInvalidSweepLeaseChunk, len(chunks), first.GetTotalChunks())
	}

	var payload []byte

	for i, chunk := range chunks {
		if chunk.GetSweepGroupId() != first.GetSweepGroupId() || chunk.GetPayloadSha256() != first.GetPayloadSha256() ||
			chunk.GetTotalChunks() != first.GetTotalChunks() {
			return nil, fmt.Errorf("%w: chunk %d belongs to a different push", errInvalidSweepLeaseChunk, i)
		}

		payload = append(payload, chunk.GetPayload()...)
	}

	sum := sha256.Sum256(payload)
	if digest := hex.EncodeToString(sum[:]); !strings.EqualFold(digest, first.GetPayloadSha256()) {
		return nil, fmt.Errorf("%w: payload digest %s, want %s", errInvalidSweepLeaseChunk, digest, first.GetPayloadSha256())
	}

	return payload, nil
}

// sweepLeaseStore holds the installed lease of each sweep group, one protobuf
// file per group under dir. The file is the installed SweepLeaseV1 (the merged
// result of every accepted push), rewritten atomically on each install, so a
// restart reloads exactly what the last ack reported as installed. A JSON
// sidecar per group records which slots the executor already ran (or refused
// terminally), keyed by execution id with the slot's collection expiry, so a
// restart never re-runs a slot and the record prunes itself once a slot can
// no longer run anyway.
type sweepLeaseStore struct {
	dir string

	mu       sync.Mutex
	leases   map[string]*edgev1.SweepLeaseV1
	executed map[string]map[string]int64
}

const sweepLeaseExecutedSuffix = ".executed.json"

func defaultSweepLeaseDir() string {
	runtimeRoot := os.Getenv("SERVICERADAR_AGENT_RUNTIME_ROOT")
	if runtime.GOOS == goosWindows && strings.TrimSpace(runtimeRoot) == "" {
		return filepath.Join(defaultStateDir(), sweepLeaseDirName)
	}

	return filepath.Join(resolveReleaseRuntimeRoot(runtimeRoot), sweepLeaseDirName)
}

// newSweepLeaseStore opens dir and reloads every installed lease in it. A
// file that no longer decodes is skipped (core re-pushes the group's full
// window once the agent's report stops covering it); the first such failure
// is returned alongside the usable store.
func newSweepLeaseStore(dir string) (*sweepLeaseStore, error) {
	if err := durablefs.MkdirAll(dir, sweepLeaseDirMode); err != nil {
		return nil, fmt.Errorf("create sweep lease dir: %w", err)
	}

	store := &sweepLeaseStore{
		dir:      dir,
		leases:   make(map[string]*edgev1.SweepLeaseV1),
		executed: make(map[string]map[string]int64),
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read sweep lease dir: %w", err)
	}

	var firstErr error

	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() {
			continue
		}

		if strings.HasSuffix(name, sweepLeaseExecutedSuffix) {
			groupID := strings.TrimSuffix(name, sweepLeaseExecutedSuffix)

			data, readErr := os.ReadFile(filepath.Join(dir, name))
			if readErr != nil {
				if firstErr == nil {
					firstErr = fmt.Errorf("read sweep lease executions %s: %w", groupID, readErr)
				}

				continue
			}

			executed := make(map[string]int64)
			if decodeErr := json.Unmarshal(data, &executed); decodeErr != nil {
				if firstErr == nil {
					firstErr = fmt.Errorf("decode sweep lease executions %s: %w", groupID, decodeErr)
				}

				continue
			}

			pruneExecuted(executed, time.Now().UnixNano())
			store.executed[groupID] = executed

			continue
		}

		if !strings.HasSuffix(name, ".pb") {
			continue
		}

		groupID := strings.TrimSuffix(name, ".pb")

		data, readErr := os.ReadFile(filepath.Join(dir, name))
		if readErr != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("read sweep lease %s: %w", groupID, readErr)
			}

			continue
		}

		var lease edgev1.SweepLeaseV1
		if unmarshalErr := goproto.Unmarshal(data, &lease); unmarshalErr != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("decode sweep lease %s: %w", groupID, unmarshalErr)
			}

			continue
		}

		store.leases[groupID] = &lease
	}

	return store, firstErr
}

// Get returns a copy of the installed lease for groupID, or nil.
func (s *sweepLeaseStore) Get(groupID string) *edgev1.SweepLeaseV1 {
	s.mu.Lock()
	defer s.mu.Unlock()

	lease, ok := s.leases[groupID]
	if !ok {
		return nil
	}

	return goproto.Clone(lease).(*edgev1.SweepLeaseV1)
}

// Groups lists the sweep groups with an installed lease, in stable order.
func (s *sweepLeaseStore) Groups() []string {
	s.mu.Lock()
	defer s.mu.Unlock()

	groups := make([]string, 0, len(s.leases))
	for groupID := range s.leases {
		groups = append(groups, groupID)
	}
	sort.Strings(groups)

	return groups
}

// Executed reports whether the executor already ran (or terminally refused)
// the slot with executionID in groupID.
func (s *sweepLeaseStore) Executed(groupID string, executionID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	_, ok := s.executed[groupID][executionID]

	return ok
}

// MarkExecuted records executionID as done for groupID when that slot is
// still on the installed lease, and persists the group's record. A missing
// lease or slot is not recorded: writing the sidecar back after a revocation
// deleted it would make a later push of the same execution skip the slot.
// Entries whose collection window has passed by now are pruned first.
func (s *sweepLeaseStore) MarkExecuted(groupID string, executionID string, collectionExpiresUnixNano int64, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if sweepLeaseSlot(s.leases[groupID], executionID) == nil {
		return nil
	}

	executed := maps.Clone(s.executed[groupID])
	if executed == nil {
		executed = make(map[string]int64)
	}

	pruneExecuted(executed, now.UnixNano())
	executed[executionID] = collectionExpiresUnixNano

	data, err := json.Marshal(executed)
	if err != nil {
		return fmt.Errorf("encode sweep lease executions: %w", err)
	}

	if err := durablefs.WriteFile(s.executedPath(groupID), data, sweepLeaseFileMode); err != nil {
		return err
	}
	s.executed[groupID] = executed
	return nil
}

func pruneExecuted(executed map[string]int64, nowUnixNano int64) {
	for executionID, expires := range executed {
		if expires <= nowUnixNano {
			delete(executed, executionID)
		}
	}
}

func (s *sweepLeaseStore) executedPath(groupID string) string {
	return filepath.Join(s.dir, groupID+sweepLeaseExecutedSuffix)
}

// Install checks push, applies it as a window replacement over the installed
// lease, persists the result, and returns the lease the agent now holds for
// the group (nil after a revocation). wantGroup is the sweep group the chunk
// stream named for this push; the lease inside must name the same group.
func (s *sweepLeaseStore) Install(push *edgev1.SweepLeaseV1, wantGroup string) (*edgev1.SweepLeaseV1, error) {
	if err := validateSweepLease(push, wantGroup); err != nil {
		return nil, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if push.GetRevoked() {
		delete(s.leases, wantGroup)
		delete(s.executed, wantGroup)

		if err := os.Remove(s.path(wantGroup)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("remove revoked sweep lease: %w", err)
		}

		if err := durablefs.Sync(s.dir); err != nil {
			return nil, fmt.Errorf("sync revoked sweep lease: %w", err)
		}

		if err := os.Remove(s.executedPath(wantGroup)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("remove revoked sweep lease executions: %w", err)
		}

		return nil, durablefs.Sync(s.dir)
	}

	installed := mergeSweepLease(s.leases[wantGroup], push)

	data, err := goproto.Marshal(installed)
	if err != nil {
		return nil, fmt.Errorf("encode sweep lease: %w", err)
	}

	if err := durablefs.WriteFile(s.path(wantGroup), data, sweepLeaseFileMode); err != nil {
		return nil, err
	}

	s.leases[wantGroup] = installed

	return goproto.Clone(installed).(*edgev1.SweepLeaseV1), nil
}

func (s *sweepLeaseStore) path(groupID string) string {
	return filepath.Join(s.dir, groupID+".pb")
}

// validateSweepLease is the install gate: the structural contract of
// SweepLeaseV1 (proto/edge/v1/sweep.proto) that must hold before any slot is
// stored. Plan and capability-structure checks happen when a slot runs
// (sweep_lease_executor.go). Cryptographic signature verification stays at
// the gateway (M2.0f). Neither is repeated here.
func validateSweepLease(push *edgev1.SweepLeaseV1, wantGroup string) error {
	if push == nil {
		return fmt.Errorf("%w: empty push", errInvalidSweepLease)
	}

	if push.GetLeaseVersion() != sweepLeaseVersion {
		return fmt.Errorf("%w: lease_version %d", errInvalidSweepLease, push.GetLeaseVersion())
	}

	group, err := uuid.FromBytes(push.GetSweepGroupId())
	if err != nil || group.String() != wantGroup {
		return fmt.Errorf("%w: sweep group does not match the push", errInvalidSweepLease)
	}

	if _, err := uuid.FromBytes(push.GetLeaseId()); err != nil {
		return fmt.Errorf("%w: lease_id is not a UUID", errInvalidSweepLease)
	}

	if push.GetWindowEndUnixNano() <= push.GetWindowStartUnixNano() {
		return fmt.Errorf("%w: window [%d, %d) is empty", errInvalidSweepLease,
			push.GetWindowStartUnixNano(), push.GetWindowEndUnixNano())
	}

	if !push.GetRevoked() && len(push.GetSlots()) > 0 && push.GetProductionCapability() == nil {
		return fmt.Errorf("%w: slots without a production capability", errInvalidSweepLease)
	}

	var previousStart int64

	for i, slot := range push.GetSlots() {
		start := slot.GetSlotStartUnixNano()

		switch {
		case i > 0 && start <= previousStart:
			return fmt.Errorf("%w: slots not strictly ascending at %d", errInvalidSweepLease, i)
		case start < push.GetWindowStartUnixNano() || start >= push.GetWindowEndUnixNano():
			return fmt.Errorf("%w: slot %d starts outside the window", errInvalidSweepLease, i)
		case slot.GetCollectionExpiresUnixNano() <= start:
			return fmt.Errorf("%w: slot %d collection window is empty", errInvalidSweepLease, i)
		}

		if _, err := uuid.FromBytes(slot.GetExecutionId()); err != nil {
			return fmt.Errorf("%w: slot %d execution_id is not a UUID", errInvalidSweepLease, i)
		}

		previousStart = start
	}

	return nil
}

// mergeSweepLease applies push as a window replacement over installed: a new
// lease id replaces the installed lease outright; otherwise every installed
// slot starting inside the push window is removed and the pushed slots are
// inserted, so a slot core dropped disappears without a delete message. The
// newest production capability wins, since core signs each push's capability
// to cover every slot the agent then holds.
func mergeSweepLease(installed, push *edgev1.SweepLeaseV1) *edgev1.SweepLeaseV1 {
	merged := goproto.Clone(push).(*edgev1.SweepLeaseV1)

	if installed == nil || string(installed.GetLeaseId()) != string(push.GetLeaseId()) {
		return merged
	}

	slots := make([]*edgev1.SweepLeaseSlotV1, 0, len(installed.GetSlots())+len(push.GetSlots()))

	for _, slot := range installed.GetSlots() {
		if start := slot.GetSlotStartUnixNano(); start < push.GetWindowStartUnixNano() || start >= push.GetWindowEndUnixNano() {
			slots = append(slots, slot)
		}
	}

	slots = append(slots, merged.GetSlots()...)
	sort.Slice(slots, func(i, j int) bool {
		return slots[i].GetSlotStartUnixNano() < slots[j].GetSlotStartUnixNano()
	})
	merged.Slots = slots

	if merged.GetProductionCapability() == nil {
		merged.ProductionCapability = installed.GetProductionCapability()
	}

	if len(slots) > 0 {
		merged.WindowStartUnixNano = slots[0].GetSlotStartUnixNano()
		merged.WindowEndUnixNano = slots[len(slots)-1].GetSlotStartUnixNano() + 1
	}

	return merged
}

// sweepLeaseAckInstalled answers a push core can record as installed: how far
// the agent can now run without core is the collection end of the last held
// slot.
func sweepLeaseAckInstalled(group string, held *edgev1.SweepLeaseV1, digest string) *proto.SweepLeaseAck {
	ack := &proto.SweepLeaseAck{
		SweepGroupId:  group,
		PayloadSha256: digest,
		Installed:     true,
	}

	if held == nil {
		return ack
	}

	ack.LeaseId = held.GetLeaseId()
	ack.InstalledSlotCount = uint32(len(held.GetSlots()))

	if slots := held.GetSlots(); len(slots) > 0 {
		ack.InstalledThroughUnixNano = slots[len(slots)-1].GetCollectionExpiresUnixNano()
	}

	return ack
}

func sweepLeaseAckRefused(group string, leaseID []byte, digest string, err error) *proto.SweepLeaseAck {
	return &proto.SweepLeaseAck{
		SweepGroupId:  group,
		LeaseId:       leaseID,
		PayloadSha256: digest,
		Installed:     false,
		Error:         err.Error(),
	}
}

// sweepLeaseStore opens the lease store on first use. Lease pushes only
// arrive once core leases to this agent, so the directory is created lazily
// rather than at agent startup.
func (p *PushLoop) sweepLeaseStore() (*sweepLeaseStore, error) {
	p.sweepLeaseMu.Lock()
	defer p.sweepLeaseMu.Unlock()

	if p.sweepLeases != nil {
		return p.sweepLeases, nil
	}

	dir := p.sweepLeaseDir
	if dir == "" {
		dir = defaultSweepLeaseDir()
	}

	store, err := newSweepLeaseStore(dir)
	if store == nil {
		return nil, err
	}

	if err != nil {
		p.logger.Warn().Err(err).Msg("Some installed sweep leases could not be reloaded")
	}

	p.sweepLeases = store

	return store, nil
}

// handleSweepLeaseChunk reassembles one lease push, installs it, and answers
// with the SweepLeaseAck core records. A push that cannot be reassembled,
// decoded, or installed is refused with the reason; core then resends the
// whole window on a later pass.
func (p *PushLoop) handleSweepLeaseChunk(chunk *proto.SweepLeaseChunk, assembler *sweepLeaseAssembler, sender *controlStreamSender) {
	group := chunk.GetSweepGroupId()
	digest := chunk.GetPayloadSha256()

	payload, err := assembler.add(chunk)
	if err != nil {
		p.logger.Warn().Err(err).Str("sweep_group_id", group).Msg("Discarded sweep lease push")
		p.sendSweepLeaseAck(sender, sweepLeaseAckRefused(group, nil, digest, err))

		return
	}

	if payload == nil {
		return
	}

	var push edgev1.SweepLeaseV1
	if err := goproto.Unmarshal(payload, &push); err != nil {
		p.logger.Warn().Err(err).Str("sweep_group_id", group).Msg("Discarded undecodable sweep lease push")
		p.sendSweepLeaseAck(sender, sweepLeaseAckRefused(group, nil, digest,
			fmt.Errorf("%w: decode lease: %w", errInvalidSweepLease, err)))

		return
	}

	store, err := p.sweepLeaseStore()
	if err != nil {
		p.logger.Warn().Err(err).Str("sweep_group_id", group).Msg("Sweep lease store unavailable")
		p.sendSweepLeaseAck(sender, sweepLeaseAckRefused(group, push.GetLeaseId(), digest, err))

		return
	}

	held, err := store.Install(&push, group)
	if err != nil {
		p.logger.Warn().Err(err).Str("sweep_group_id", group).Msg("Refused sweep lease push")
		p.sendSweepLeaseAck(sender, sweepLeaseAckRefused(group, push.GetLeaseId(), digest, err))

		return
	}

	p.onSweepLeaseInstalled(group, held)
	p.sendSweepLeaseAck(sender, sweepLeaseAckInstalled(group, held, digest))
}

func (p *PushLoop) sendSweepLeaseAck(sender *controlStreamSender, ack *proto.SweepLeaseAck) {
	if err := sender.Send(&proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_SweepLeaseAck{SweepLeaseAck: ack},
	}); err != nil {
		p.logger.Warn().
			Err(err).
			Str("sweep_group_id", ack.GetSweepGroupId()).
			Msg("Failed to send sweep lease ack")
	}
}
