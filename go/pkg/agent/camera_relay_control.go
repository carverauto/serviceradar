package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

// Observations live only until the original command deadline. They are not a
// durable retirement journal and must never authorize a replacement source.
const (
	maxCameraRelayStartOperations = 4096
	maxCameraRelayStopOperations  = 4096
	maxCameraRelayCommandTTL      = 5 * time.Minute
)

// Wire values of camera.reconcile_relay_stop observation states.
const (
	cameraRelayStopStateUnknown    = "unknown"
	cameraRelayStopStatePending    = "pending"
	cameraRelayStopStateCompleted  = "completed"
	cameraRelayStopStateUnresolved = "unresolved"
)

var (
	errCameraRelayStartEnvelope     = errors.New("camera relay open requires an operation ID and a valid deadline within five minutes")
	errCameraRelayStartConflict     = errors.New("camera relay open operation content conflict")
	errCameraRelayStartCapacity     = errors.New("camera relay open receipt capacity reached")
	errCameraRelayStopEnvelope      = errors.New("camera relay stop requires an operation ID and a valid deadline within five minutes")
	errCameraRelayStopConflict      = errors.New("camera relay stop operation content conflict")
	errCameraRelayStopCapacity      = errors.New("camera relay stop observation capacity reached")
	errCameraRelaySourceCloseFailed = errors.New("camera relay source close unresolved")
	errCameraRelayStopQuery         = errors.New("operation_id, relay_session_id and source_incarnation_id are required")
)

// Open and tracked stop receipts have the same bounded original envelope.
func cameraRelayCommandDeadline(cmd *proto.CommandRequest, now time.Time) (time.Time, bool) {
	if strings.TrimSpace(cmd.GetCommandId()) == "" || cmd.GetCreatedAt() <= 0 || cmd.GetTtlSeconds() <= 0 ||
		cmd.GetTtlSeconds() > int64(maxCameraRelayCommandTTL/time.Second) {
		return time.Time{}, false
	}
	expiresAt := time.Unix(cmd.GetCreatedAt(), 0).Add(time.Duration(cmd.GetTtlSeconds()) * time.Second)
	return expiresAt, expiresAt.After(now) && !expiresAt.After(now.Add(maxCameraRelayCommandTTL))
}

// The digest avoids retaining source credentials with a historical receipt.
// Result fields are written once, before done closes.
type cameraRelayStartOperation struct {
	digest    [sha256.Size]byte
	createdAt int64
	ttl       int64
	expiresAt time.Time
	done      chan struct{}
	state     *cameraRelaySessionState
	err       error
}

// StartCommand returns the original startup outcome, not current source liveness.
// Records belong to this registry lifetime only; this is not restart fencing.
func (m *cameraRelayManager) StartCommand(ctx context.Context, cmd *proto.CommandRequest, spec cameraRelaySessionSpec) (*cameraRelaySessionState, error) {
	if m == nil || m.gateway == nil {
		return nil, errCameraRelayGatewayUnavailable
	}
	spec, err := normalizeCameraRelaySpec(spec)
	if err != nil {
		return nil, err
	}
	if spec.GatewayID == "" {
		spec.GatewayID = strings.TrimSpace(m.gateway.GetGatewayID())
	}
	content, err := json.Marshal(spec)
	if err != nil {
		return nil, err
	}
	operation, first, err := m.captureStartOperation(cmd, sha256.Sum256(content))
	if err != nil {
		return nil, err
	}
	if first {
		operation.state, operation.err = m.Start(ctx, spec)
		close(operation.done)
		return operation.outcome()
	}
	waitCtx, cancel := context.WithDeadline(ctx, operation.expiresAt)
	defer cancel()
	select {
	case <-operation.done:
	case <-waitCtx.Done():
		select {
		case <-operation.done:
		default:
			return nil, waitCtx.Err()
		}
	}
	return operation.outcome()
}

func (operation *cameraRelayStartOperation) outcome() (*cameraRelaySessionState, error) {
	if operation.state == nil {
		return nil, operation.err
	}
	state := *operation.state
	return &state, operation.err
}

func (m *cameraRelayManager) captureStartOperation(cmd *proto.CommandRequest, digest [sha256.Size]byte) (*cameraRelayStartOperation, bool, error) {
	now := time.Now()
	expiresAt, valid := cameraRelayCommandDeadline(cmd, now)
	if !valid {
		return nil, false, errCameraRelayStartEnvelope
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	for id, operation := range m.startOperations {
		if !operation.expiresAt.After(now) {
			delete(m.startOperations, id)
		}
	}
	if operation, ok := m.startOperations[cmd.GetCommandId()]; ok {
		if operation.digest != digest || operation.createdAt != cmd.GetCreatedAt() || operation.ttl != cmd.GetTtlSeconds() {
			return nil, false, errCameraRelayStartConflict
		}
		return operation, false, nil
	}
	if len(m.startOperations) >= maxCameraRelayStartOperations {
		return nil, false, errCameraRelayStartCapacity
	}
	operation := &cameraRelayStartOperation{
		digest: digest, createdAt: cmd.GetCreatedAt(), ttl: cmd.GetTtlSeconds(), expiresAt: expiresAt, done: make(chan struct{}),
	}
	m.startOperations[cmd.GetCommandId()] = operation
	return operation, true, nil
}

type cameraRelayStopOperation struct {
	payload   cameraRelayStopPayload
	createdAt int64
	ttl       int64
	expiresAt time.Time
	handle    *cameraRelayHandle
}

type cameraRelayStopQuery struct {
	OperationID         string `json:"operation_id"`
	RelaySessionID      string `json:"relay_session_id"`
	SourceIncarnationID string `json:"source_incarnation_id"`
}

type cameraRelayStopObservation struct {
	cameraRelayStopQuery
	State           string `json:"state"`
	CameraSourceID  string `json:"camera_source_id,omitempty"`
	StreamProfileID string `json:"stream_profile_id,omitempty"`
}

func (m *cameraRelayManager) StopCommand(ctx context.Context, cmd *proto.CommandRequest, payload cameraRelayStopPayload) error {
	// Legacy commands remain untracked, but cannot strip the incarnation from
	// a retained operation and thereby stop a later session with the same ID.
	if payload.SourceIncarnationID == "" {
		if m != nil {
			m.mu.Lock()
			m.pruneStopOperations(time.Now())
			_, tracked := m.stopOperations[cmd.GetCommandId()]
			m.mu.Unlock()
			if tracked {
				return errCameraRelayStopConflict
			}
		}
		return m.Stop(ctx, payload)
	}
	if m == nil || payload.SourceIncarnationID != m.incarnationID {
		return errCameraRelayIncarnationMismatch
	}
	payload.RelaySessionID = strings.TrimSpace(payload.RelaySessionID)
	if payload.RelaySessionID == "" {
		return errCameraRelaySessionIDRequired
	}
	payload.Reason = strings.TrimSpace(payload.Reason)
	if payload.Reason == "" {
		payload.Reason = "camera relay stopped"
	}
	handle, err := m.captureStopOperation(cmd, payload)
	if err != nil {
		return err
	}
	return stopCameraRelayHandle(ctx, handle, payload.Reason)
}

func (m *cameraRelayManager) captureStopOperation(cmd *proto.CommandRequest, payload cameraRelayStopPayload) (*cameraRelayHandle, error) {
	now := time.Now()
	expiresAt, valid := cameraRelayCommandDeadline(cmd, now)
	if !valid {
		return nil, errCameraRelayStopEnvelope
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneStopOperations(now)
	if operation, ok := m.stopOperations[cmd.GetCommandId()]; ok {
		if operation.payload != payload || operation.createdAt != cmd.GetCreatedAt() || operation.ttl != cmd.GetTtlSeconds() {
			return nil, errCameraRelayStopConflict
		}
		return operation.handle, nil
	}
	if len(m.stopOperations) >= maxCameraRelayStopOperations {
		return nil, errCameraRelayStopCapacity
	}
	handle := m.sessions[payload.RelaySessionID]
	if handle == nil {
		return nil, errCameraRelaySessionNotFound
	}
	m.stopOperations[cmd.GetCommandId()] = cameraRelayStopOperation{
		payload: payload, createdAt: cmd.GetCreatedAt(), ttl: cmd.GetTtlSeconds(), expiresAt: expiresAt, handle: handle,
	}
	return handle, nil
}

// Caller holds mu. Expired records become unknown, never inferred completed.
func (m *cameraRelayManager) pruneStopOperations(now time.Time) {
	for id, operation := range m.stopOperations {
		if !operation.expiresAt.After(now) {
			delete(m.stopOperations, id)
		}
	}
}

func (m *cameraRelayManager) ReconcileStop(query cameraRelayStopQuery) (*cameraRelayStopObservation, error) {
	if query.OperationID == "" || query.RelaySessionID == "" || query.SourceIncarnationID == "" {
		return nil, errCameraRelayStopQuery
	}
	if m == nil || query.SourceIncarnationID != m.incarnationID {
		return nil, errCameraRelayIncarnationMismatch
	}
	m.mu.Lock()
	m.pruneStopOperations(time.Now())
	operation, ok := m.stopOperations[query.OperationID]
	m.mu.Unlock()
	observation := &cameraRelayStopObservation{cameraRelayStopQuery: query, State: cameraRelayStopStateUnknown}
	if !ok {
		return observation, nil
	}
	if operation.payload.RelaySessionID != query.RelaySessionID || operation.payload.SourceIncarnationID != query.SourceIncarnationID {
		return nil, errCameraRelayStopConflict
	}
	observation.CameraSourceID = operation.handle.source.cameraSourceID
	observation.StreamProfileID = operation.handle.source.streamProfileID
	observation.State = cameraRelayStopStatePending
	select {
	case <-operation.handle.done:
		observation.State = cameraRelayStopStateCompleted
		if operation.handle.closeErr != nil {
			observation.State = cameraRelayStopStateUnresolved
		}
	default:
	}
	return observation, nil
}

func (p *PushLoop) handleCameraRelayReconcileStop(cmd *proto.CommandRequest, sender *controlStreamSender) {
	query := cameraRelayStopQuery{}
	if err := json.Unmarshal(cmd.PayloadJson, &query); err != nil {
		_ = sender.Send(commandResult(cmd, false, "invalid camera relay stop query", nil))
		return
	}
	observation, err := p.cameraRelayManager.ReconcileStop(query)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}
	_ = sender.Send(commandResult(cmd, true, "camera relay stop observation", observation))
}
