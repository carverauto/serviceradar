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

// Package sender is the minimum production sender that drives records out of
// the agent spool (go/pkg/edge/spool) over one EdgeRecordIngestService.Stream
// gRPC session to the agent-gateway.
//
// Scope, per task 0.12 of openspec/changes/unify-sweep-results-proto: one
// bounded lane-open/send/drain-acks cycle sufficient to carry a committed
// spool record through the real composed path end to end. Before a session it
// obtains delivery grants for records whose production authority has lapsed
// (grants.go, M2.0g). Credit renewal and recovery/rollover remain outside this
// sender. Optional local
// disposition persistence advances the resolved prefix and reclaims a drained
// segment once every record is accepted or permanently rejected; the spool keeps
// permanently rejected records in its bounded local quarantine. Unresolved
// records stay on disk.
//
// # The negative reclaim rule
//
// design.md is explicit: the wire resolved_through_sequence a gateway ack
// reports is a REMOTE watermark. The agent's LOCAL reclaim watermark
// (spool.Spool.Resolve) may only advance after the agent's own local
// durability for that sequence commits -- never directly from the wire ack.
// Without PersistAcknowledgements the remote watermark remains in memory only.
// With it, the resolving prefix of the validated acknowledgement is fsynced
// before the local watermark advances. resolvingPrefix states which dispositions
// that prefix keeps. Only that local durability can reclaim a drained segment,
// and only once every record is accepted or permanently rejected. A remote
// watermark alone never does.
//
// # Ambiguous sequence gaps
//
// The spool never reuses a sequence that restart resolution left AMBIGUOUS, and
// spool.ScanFrom never visits one, so after a crash mid-append this sender sends the
// committed sequences on either side of the gap. The gateway's disposition for the
// first sequence past the gap is not the session's resolved watermark plus one, so
// edgerecord.ValidateAck rejects the ack; every later run replays from the same
// watermark and fails the same way. The lane stays wedged on the gap until the
// wire-level rollover/coverage handling of task 2.27 carries ambiguous sequences to
// the gateway. This is a known limitation of this opt-in, unreleased sender.
package sender

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// streamFinishTimeout bounds how long a session waits, after its last
// acknowledgement, for the gateway to end the RPC. The gateway ends it as soon
// as nothing it admitted is still in flight, so this only matters when the
// gateway stops answering.
const streamFinishTimeout = 5 * time.Second

// sessionNonceBytes is the size of the fresh random nonce generated for each
// lane-open handshake; within edgerecord's [MinNonceBytes, MaxNonceBytes].
const sessionNonceBytes = 32

// ErrUnexpectedPayload is returned when the gateway sends a server-message
// payload out of the expected handshake/ack order.
var ErrUnexpectedPayload = errors.New("sender: unexpected server message payload")

// ErrNoUnresolvedRecords is returned by RunOnce when the spool has nothing to
// send; callers may treat this as a no-op rather than an error.
var ErrNoUnresolvedRecords = errors.New("sender: no unresolved spool records")

// ErrInsufficientCredits is returned by RunOnce when the spool has unresolved
// records but the gateway's granted credit window is too small to send even
// the first one. Unlike ErrNoUnresolvedRecords, this is a stall condition
// callers must not silently ignore.
var ErrInsufficientCredits = errors.New("sender: granted credit window too small for smallest unresolved record")

// errByteCreditsOutOfRange and errFrameCreditsOutOfRange are returned by
// Config.validate when the requested credit window is zero or exceeds the
// edgerecord-defined maximum.
var (
	errByteCreditsOutOfRange  = errors.New("sender: requested byte credits out of range")
	errFrameCreditsOutOfRange = errors.New("sender: requested frame credits out of range")
)

// errSpoolRequired and errClientRequired are returned by New when a required
// dependency is nil.
var (
	errSpoolRequired  = errors.New("sender: spool is required")
	errClientRequired = errors.New("sender: client is required")
)

// StreamClient is the subset of edgev1.EdgeRecordIngestServiceClient the
// sender needs, so tests can inject a fake without a real gRPC connection.
type StreamClient interface {
	Stream(ctx context.Context, opts ...grpc.CallOption) (
		grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage], error,
	)
}

// Config identifies one delivery lane. SpoolID is the persistent per-lane
// UUIDv7 (see PersistentSpoolID); RouteProfile/TrafficClass select the finite
// platform-owned lane the gateway session negotiates.
type Config struct {
	SpoolID               []byte
	RouteProfile          edgev1.EdgeRecordRouteProfile
	TrafficClass          edgev1.EdgeRecordTrafficClass
	RequestedByteCredits  uint64
	RequestedFrameCredits uint32
	// PersistAcknowledgements fsyncs the resolving prefix of a validated
	// acknowledgement before suppressing that prefix's replay, and reclaims a
	// drained segment, quarantining its permanently rejected records first.
	// Unresolved records stay on disk.
	PersistAcknowledgements bool
	// Grants, when set, obtains delivery grants for records whose production
	// authority has lapsed before each session sends them (see grants.go).
	Grants GrantRenewer
}

func (c Config) validate() error {
	if err := edgerecord.ValidateUUIDv7(c.SpoolID); err != nil {
		return fmt.Errorf("sender: spool id: %w", err)
	}
	if c.RequestedByteCredits == 0 || c.RequestedByteCredits > edgerecord.MaxByteCredits {
		return errByteCreditsOutOfRange
	}
	if c.RequestedFrameCredits == 0 || c.RequestedFrameCredits > edgerecord.MaxFrameCredits {
		return errFrameCreditsOutOfRange
	}
	return nil
}

// Result reports what one RunOnce call observed. RemoteResolvedThrough is the
// gateway's cumulative remote watermark ONLY -- it is informational and is
// never used alone as the spool's local reclaim watermark.
type Result struct {
	Sent                  []uint64
	Dispositions          []*edgev1.EdgeRecordDisposition
	RemoteResolvedThrough uint64
	// GrantRenewal is why delivery grants could not be obtained for this run,
	// if they could not. The run still sends; records that needed a grant are
	// refused by the gateway and stay unresolved for the next run.
	GrantRenewal error
}

// Sender drains one agent spool over one lane session.
type Sender struct {
	spool  *spool.Spool
	client StreamClient
	cfg    Config
	// grants holds the delivery grants obtained for unresolved records, by
	// sequence. Only the run loop touches it.
	grants map[uint64]heldGrant
}

// New builds a Sender for the given spool, client, and lane configuration.
func New(sp *spool.Spool, client StreamClient, cfg Config) (*Sender, error) {
	if sp == nil {
		return nil, errSpoolRequired
	}
	if client == nil {
		return nil, errClientRequired
	}
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &Sender{spool: sp, client: client, cfg: cfg, grants: make(map[uint64]heldGrant)}, nil
}

// RunOnce opens one lane session, sends every currently-unresolved spool
// record up to the gateway-granted credit window, and drains dispositions
// until every sent sequence is resolved, the stream ends, or ctx is done. It
// persists the resolving prefix of a validated acknowledgement only when
// configured to do so.
func (s *Sender) RunOnce(ctx context.Context) (Result, error) {
	grantErr := s.renewGrants(ctx)
	result, err := s.runSession(ctx)
	result.GrantRenewal = grantErr
	return result, err
}

func (s *Sender) runSession(ctx context.Context) (Result, error) {
	if s.cfg.PersistAcknowledgements {
		if err := s.spool.ReclaimResolved(); err != nil {
			return Result{}, fmt.Errorf("sender: reclaim accepted records: %w", err)
		}
	}

	// With nothing to deliver there is no session to open.
	pending, err := s.hasUnresolved()
	if err != nil {
		return Result{}, err
	}
	if !pending {
		return Result{RemoteResolvedThrough: s.spool.Resolved()}, ErrNoUnresolvedRecords
	}

	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	stream, err := s.client.Stream(streamCtx)
	if err != nil {
		return Result{}, fmt.Errorf("sender: open stream: %w", err)
	}

	nonce, err := randomNonce()
	if err != nil {
		return Result{}, fmt.Errorf("sender: session nonce: %w", err)
	}

	firstUnresolved := s.spool.Resolved() + 1

	open := &edgev1.EdgeRecordLaneOpen{
		RouteProfile:            s.cfg.RouteProfile,
		TrafficClass:            s.cfg.TrafficClass,
		SpoolId:                 s.cfg.SpoolID,
		SequenceBase:            1,
		FirstUnresolvedSequence: firstUnresolved,
		SessionNonce:            nonce,
		RequestedByteCredits:    s.cfg.RequestedByteCredits,
		RequestedFrameCredits:   s.cfg.RequestedFrameCredits,
	}
	if err := edgerecord.ValidateLaneOpen(open); err != nil {
		return Result{}, fmt.Errorf("sender: built lane_open failed local validation: %w", err)
	}

	if err := stream.Send(&edgev1.EdgeRecordClientMessage{
		Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: open},
	}); err != nil {
		return Result{}, fmt.Errorf("sender: send lane_open: %w", err)
	}

	openAck, err := recvLaneOpenAck(stream, open)
	if err != nil {
		return Result{}, err
	}

	sess := edgerecord.Session{
		RouteProfile:    open.GetRouteProfile(),
		TrafficClass:    open.GetTrafficClass(),
		SpoolID:         s.cfg.SpoolID,
		Nonce:           nonce,
		FirstUnresolved: firstUnresolved,
		NextSequence:    firstUnresolved,
		HighestSent:     firstUnresolved - 1,
		ResolvedThrough: firstUnresolved - 1,
		SentEvents:      make(map[uint64][]byte),
	}

	sent, hadUnresolved, err := s.sendUnresolved(stream, &sess, openAck)
	if err != nil {
		return partialSendResult(sent, sess.ResolvedThrough), err
	}

	if len(sent) == 0 {
		finishStream(stream, cancel)
		if hadUnresolved {
			return Result{RemoteResolvedThrough: sess.ResolvedThrough}, ErrInsufficientCredits
		}
		return Result{RemoteResolvedThrough: sess.ResolvedThrough}, ErrNoUnresolvedRecords
	}

	if err := stream.CloseSend(); err != nil {
		return partialSendResult(sent, sess.ResolvedThrough), fmt.Errorf("sender: close send: %w", err)
	}

	dispositions, err := s.drainAcks(ctx, stream, &sess)
	result := Result{
		Sent:                  sent,
		Dispositions:          dispositions,
		RemoteResolvedThrough: sess.ResolvedThrough,
	}
	if err != nil {
		return result, err
	}

	finishStream(stream, cancel)
	return result, nil
}

// hasUnresolved reports whether the spool holds a record no session has
// resolved yet, reading at most one record.
func (s *Sender) hasUnresolved() (bool, error) {
	found := false
	if err := s.spool.ScanFrom(0, func(spool.Record) bool {
		found = true
		return false
	}); err != nil {
		return false, fmt.Errorf("sender: scan spool: %w", err)
	}
	return found, nil
}

// finishStream half-closes the session and reads until the gateway ends the
// RPC, so a finished session completes with status OK instead of being torn
// down by cancelling its context (which gRPC reports, and tracing records, as
// CANCELLED). Every outcome the session needs has already been read; anything
// else the gateway sends is discarded. A gateway that does not end the RPC
// within streamFinishTimeout is cancelled as before.
func finishStream(
	stream grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage],
	cancel context.CancelFunc,
) {
	if err := stream.CloseSend(); err != nil {
		return
	}

	timer := time.AfterFunc(streamFinishTimeout, cancel)
	defer timer.Stop()

	for {
		if _, err := stream.Recv(); err != nil {
			return
		}
	}
}

func partialSendResult(sent []uint64, remoteResolvedThrough uint64) Result {
	return Result{Sent: sent, RemoteResolvedThrough: remoteResolvedThrough}
}

func recvLaneOpenAck(
	stream grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage],
	open *edgev1.EdgeRecordLaneOpen,
) (*edgev1.EdgeRecordLaneOpenAck, error) {
	msg, err := stream.Recv()
	if err != nil {
		return nil, fmt.Errorf("sender: recv lane_open_ack: %w", err)
	}
	if err := edgerecord.ValidateServerMessage(msg); err != nil {
		return nil, fmt.Errorf("sender: lane_open_ack envelope: %w", err)
	}
	ack := msg.GetLaneOpenAck()
	if ack == nil {
		return nil, fmt.Errorf("%w: expected lane_open_ack, got %T", ErrUnexpectedPayload, msg.GetPayload())
	}
	if err := edgerecord.ValidateLaneOpenAck(ack, open); err != nil {
		return nil, fmt.Errorf("sender: lane_open_ack: %w", err)
	}
	return ack, nil
}

// sendUnresolved streams every unresolved spool record up to the granted
// credit window, updating sess bookkeeping as it goes. Record bodies are read
// off disk one at a time and the scan stops once the window is exhausted, so a
// small credit window never reads a large backlog (spool.ScanFrom's contract).
func (s *Sender) sendUnresolved(
	stream grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage],
	sess *edgerecord.Session,
	ack *edgev1.EdgeRecordLaneOpenAck,
) ([]uint64, bool, error) {
	var (
		sent          []uint64
		framesUsed    uint32
		bytesUsed     uint64
		sendErr       error
		hadUnresolved bool
	)

	scanErr := s.spool.ScanFrom(0, func(rec spool.Record) bool {
		hadUnresolved = true
		if framesUsed >= ack.GetGrantedFrameCredits() {
			return false
		}
		if bytesUsed+uint64(len(rec.Body)) > ack.GetGrantedByteCredits() {
			return false
		}

		frame := buildFrame(s.cfg.SpoolID, rec)
		frame.DeliveryCapability = s.grantFor(rec)
		if err := edgerecord.ValidateDeliveryFrame(frame, false); err != nil {
			sendErr = fmt.Errorf("sender: built frame failed local validation: %w", err)
			return false
		}
		if err := stream.Send(&edgev1.EdgeRecordClientMessage{
			Payload: &edgev1.EdgeRecordClientMessage_DeliveryFrame{DeliveryFrame: frame},
		}); err != nil {
			sendErr = fmt.Errorf("sender: send delivery_frame seq=%d: %w", rec.Sequence, err)
			return false
		}

		sess.SentEvents[rec.Sequence] = rec.EventID
		sess.HighestSent = rec.Sequence
		sess.NextSequence = rec.Sequence + 1
		framesUsed++
		bytesUsed += uint64(len(rec.Body))
		sent = append(sent, rec.Sequence)
		return true
	})
	if scanErr != nil {
		return sent, hadUnresolved, fmt.Errorf("sender: scan spool: %w", scanErr)
	}
	if sendErr != nil {
		return sent, hadUnresolved, sendErr
	}

	return sent, hadUnresolved, nil
}

func buildFrame(spoolID []byte, rec spool.Record) *edgev1.EdgeDeliveryFrameV1 {
	sum := sha256.Sum256(rec.Body)
	return &edgev1.EdgeDeliveryFrameV1{
		SpoolId:      spoolID,
		Sequence:     rec.Sequence,
		RecordSha256: sum[:],
		RecordBytes:  rec.Body,
	}
}

// drainAcks reads dispositions until every sent sequence is resolved, the
// stream ends, or ctx is canceled. Optional durable disposition evidence precedes
// the local resolved watermark.
func (s *Sender) drainAcks(
	ctx context.Context,
	stream grpc.BidiStreamingClient[edgev1.EdgeRecordClientMessage, edgev1.EdgeRecordServerMessage],
	sess *edgerecord.Session,
) ([]*edgev1.EdgeRecordDisposition, error) {
	var dispositions []*edgev1.EdgeRecordDisposition

	for sess.ResolvedThrough < sess.HighestSent {
		if err := ctx.Err(); err != nil {
			return dispositions, fmt.Errorf("sender: %w waiting for ack", err)
		}

		msg, err := stream.Recv()
		if err != nil {
			return dispositions, fmt.Errorf("sender: recv ack: %w", err)
		}
		if err := edgerecord.ValidateServerMessage(msg); err != nil {
			return dispositions, fmt.Errorf("sender: ack envelope: %w", err)
		}
		ack := msg.GetAck()
		if ack == nil {
			return dispositions, fmt.Errorf("%w: expected ack, got %T", ErrUnexpectedPayload, msg.GetPayload())
		}
		if err := edgerecord.ValidateAck(ack, *sess, 0, 0); err != nil {
			return dispositions, fmt.Errorf("sender: ack: %w", err)
		}

		if err := s.persistAcknowledgement(ack, sess.ResolvedThrough); err != nil {
			return dispositions, err
		}

		dispositions = append(dispositions, ack.GetDispositions()...)
		// Advance the session only after any required local durability barrier.
		sess.ResolvedThrough = ack.GetResolvedThroughSequence()
	}

	return dispositions, nil
}

func (s *Sender) persistAcknowledgement(ack *edgev1.EdgeDeliveryAckV1, previous uint64) error {
	if !s.cfg.PersistAcknowledgements || ack.GetResolvedThroughSequence() <= previous {
		return nil
	}
	evidence, err := proto.MarshalOptions{Deterministic: true}.Marshal(resolvingPrefix(ack))
	if err != nil {
		return err
	}
	if err := s.spool.ResolveWithEvidence(ack.GetResolvedThroughSequence(), evidence); err != nil {
		return fmt.Errorf("sender: persist terminal acknowledgement: %w", err)
	}
	return nil
}

// resolvingPrefix is the acknowledgement this lane persists: everything at or
// below resolved_through_sequence. ValidateAck also accepts retryable
// dispositions past the watermark; they resolve nothing, their records stay
// unresolved and are re-sent, and persisting them would spend terminal evidence
// credit the resolved records did not prepay and keep reclaim from proving the
// prefix accepted.
func resolvingPrefix(ack *edgev1.EdgeDeliveryAckV1) *edgev1.EdgeDeliveryAckV1 {
	through := ack.GetResolvedThroughSequence()
	trimmed := false
	for _, d := range ack.GetDispositions() {
		if d.GetSequence() > through {
			trimmed = true
			break
		}
	}
	if !trimmed {
		return ack
	}
	prefix := proto.Clone(ack).(*edgev1.EdgeDeliveryAckV1)
	prefix.Dispositions = prefix.Dispositions[:0]
	for _, d := range ack.GetDispositions() {
		if d.GetSequence() <= through {
			prefix.Dispositions = append(prefix.Dispositions, proto.Clone(d).(*edgev1.EdgeRecordDisposition))
		}
	}
	return prefix
}

func randomNonce() ([]byte, error) {
	b := make([]byte, sessionNonceBytes)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	return b, nil
}

// PersistentSpoolID returns the durable lane spool_id stored alongside the
// spool directory, generating and persisting a fresh UUIDv7 on first use. The
// wire protocol requires a stable spool_id per lane across restarts (a
// reconnect replays from its declared base under the SAME id); this file is
// the minimum durable state needed for that, distinct from the spool's own
// segment/watermark files.
func PersistentSpoolID(dir string) ([]byte, error) {
	if err := durablefs.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("sender: mkdir: %w", err)
	}
	path := filepath.Join(dir, "spool_id")

	if b, err := os.ReadFile(path); err == nil {
		if err := edgerecord.ValidateUUIDv7(b); err != nil {
			return nil, fmt.Errorf("sender: stored spool id: %w", err)
		}
		if err := durablefs.Sync(path); err != nil {
			return nil, fmt.Errorf("sender: sync spool id: %w", err)
		}
		return b, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("sender: read spool id: %w", err)
	}

	id, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("sender: generate spool id: %w", err)
	}
	if err := durablefs.WriteFile(path, id, 0o600); err != nil {
		return nil, fmt.Errorf("sender: write spool id: %w", err)
	}
	return id, nil
}
