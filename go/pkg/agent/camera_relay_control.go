package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

// Observations live only until the original command deadline. They are not a
// durable retirement journal and must never authorize a replacement source.
const (
	maxCameraRelayStopOperations = 4096
	maxCameraRelayStopTTL        = 5 * time.Minute
)

// Wire values of camera.reconcile_relay_stop observation states.
const (
	cameraRelayStopStateUnknown    = "unknown"
	cameraRelayStopStatePending    = "pending"
	cameraRelayStopStateCompleted  = "completed"
	cameraRelayStopStateUnresolved = "unresolved"
)

var (
	errCameraRelayStopEnvelope      = errors.New("camera relay stop requires an operation ID and a valid deadline within five minutes")
	errCameraRelayStopConflict      = errors.New("camera relay stop operation content conflict")
	errCameraRelayStopCapacity      = errors.New("camera relay stop observation capacity reached")
	errCameraRelaySourceCloseFailed = errors.New("camera relay source close unresolved")
	errCameraRelayStopQuery         = errors.New("operation_id, relay_session_id and source_incarnation_id are required")
)

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
	expiresAt := time.Unix(cmd.GetCreatedAt(), 0).Add(time.Duration(cmd.GetTtlSeconds()) * time.Second)
	if strings.TrimSpace(cmd.GetCommandId()) == "" || cmd.GetCreatedAt() <= 0 || cmd.GetTtlSeconds() <= 0 ||
		cmd.GetTtlSeconds() > int64(maxCameraRelayStopTTL/time.Second) ||
		!expiresAt.After(now) || expiresAt.After(now.Add(maxCameraRelayStopTTL)) {
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
