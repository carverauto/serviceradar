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
// spool record through the real composed path end to end. Reconnect/replay,
// credit renewal, recovery/rollover, and the agent-local positive reclaim
// watermark are explicitly out of scope and are NOT implemented here.
//
// # The negative reclaim rule
//
// design.md is explicit: the wire resolved_through_sequence a gateway ack
// reports is a REMOTE watermark. The agent's LOCAL reclaim watermark
// (spool.Spool.Resolve) may only advance after the agent's own local
// durability for that sequence commits -- never directly from the wire ack.
// This package tracks the remote watermark only in memory (Result) for
// observability and tests; it never calls (*spool.Spool).Resolve. Physically
// reclaiming the spool from confirmed remote delivery remains the explicit
// responsibility of a later milestone (task 0.12's own scope note, group D).
package sender

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

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
// never fed back into the spool's local reclaim watermark.
type Result struct {
	Sent                  []uint64
	Dispositions          []*edgev1.EdgeRecordDisposition
	RemoteResolvedThrough uint64
}

// Sender drains one agent spool over one lane session.
type Sender struct {
	spool  *spool.Spool
	client StreamClient
	cfg    Config
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
	return &Sender{spool: sp, client: client, cfg: cfg}, nil
}

// RunOnce opens one lane session, sends every currently-unresolved spool
// record up to the gateway-granted credit window, and drains dispositions
// until every sent sequence is resolved, the stream ends, or ctx is done. It
// never calls (*spool.Spool).Resolve -- see the package doc for why.
func (s *Sender) RunOnce(ctx context.Context) (Result, error) {
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
		return Result{}, err
	}

	if len(sent) == 0 {
		if hadUnresolved {
			return Result{RemoteResolvedThrough: sess.ResolvedThrough}, ErrInsufficientCredits
		}
		return Result{RemoteResolvedThrough: sess.ResolvedThrough}, ErrNoUnresolvedRecords
	}

	if err := stream.CloseSend(); err != nil {
		return Result{}, fmt.Errorf("sender: close send: %w", err)
	}

	dispositions, err := drainAcks(ctx, stream, &sess)
	result := Result{
		Sent:                  sent,
		Dispositions:          dispositions,
		RemoteResolvedThrough: sess.ResolvedThrough,
	}
	if err != nil {
		return result, err
	}

	return result, nil
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
// credit window, updating sess bookkeeping as it goes. Only the records
// visit chooses to send are read off disk, so a large backlog is never
// materialized to apply a small credit window (spool.ScanFrom's contract).
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
// stream ends, or ctx is canceled. sess.ResolvedThrough is updated in memory
// ONLY; it is never passed to (*spool.Spool).Resolve (see package doc).
func drainAcks(
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

		dispositions = append(dispositions, ack.GetDispositions()...)
		// In-memory bookkeeping only. The remote watermark never drives local
		// reclaim: see the package doc and design.md's two-watermark rule.
		sess.ResolvedThrough = ack.GetResolvedThroughSequence()
	}

	return dispositions, nil
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
	path := filepath.Join(dir, "spool_id")

	if b, err := os.ReadFile(path); err == nil {
		if err := edgerecord.ValidateUUIDv7(b); err != nil {
			return nil, fmt.Errorf("sender: stored spool id: %w", err)
		}
		return b, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("sender: read spool id: %w", err)
	}

	id, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, fmt.Errorf("sender: generate spool id: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("sender: mkdir: %w", err)
	}
	if err := os.WriteFile(path, id, 0o600); err != nil {
		return nil, fmt.Errorf("sender: write spool id: %w", err)
	}
	return id, nil
}
