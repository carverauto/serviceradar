package sdk

import (
	"context"
	"encoding/json"
	"errors"
)

var errCameraMediaStreamNotInitialized = errors.New("camera media stream not initialized")

// CameraMediaOpenRequest defines metadata needed to open a host camera media stream.
type CameraMediaOpenRequest struct {
	TrackID       string `json:"track_id,omitempty"`
	Codec         string `json:"codec,omitempty"`
	PayloadFormat string `json:"payload_format,omitempty"`
}

// CameraMediaChunkMetadata describes an uploaded camera media chunk.
type CameraMediaChunkMetadata struct {
	TrackID       string `json:"track_id,omitempty"`
	Sequence      uint64 `json:"sequence,omitempty"`
	PTS           int64  `json:"pts,omitempty"`
	DTS           int64  `json:"dts,omitempty"`
	Keyframe      bool   `json:"keyframe,omitempty"`
	IsFinal       bool   `json:"is_final,omitempty"`
	Codec         string `json:"codec,omitempty"`
	PayloadFormat string `json:"payload_format,omitempty"`
}

// CameraMediaHeartbeat keeps a host camera media stream lease alive.
type CameraMediaHeartbeat struct {
	Sequence      uint64 `json:"sequence,omitempty"`
	TimestampUnix int64  `json:"timestamp_unix,omitempty"`
}

// CameraMediaStream wraps a host camera media stream handle.
type CameraMediaStream struct {
	handle uint32
}

// OpenCameraMediaStream opens a host camera media stream.
func OpenCameraMediaStream(req CameraMediaOpenRequest) (*CameraMediaStream, error) {
	return OpenCameraMediaStreamContext(context.Background(), req)
}

// OpenCameraMediaStreamContext opens a host camera media stream with a context.
func OpenCameraMediaStreamContext(ctx context.Context, req CameraMediaOpenRequest) (*CameraMediaStream, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	res := hostCameraMediaOpen(ptrFromBytes(payload), uint32(len(payload)))
	if res < 0 {
		return nil, hostErr(res, "camera_media_open")
	}

	return &CameraMediaStream{handle: uint32(res)}, nil
}

// Write uploads a camera media chunk to the host stream.
func (s *CameraMediaStream) Write(meta CameraMediaChunkMetadata, payload []byte) error {
	return s.WriteContext(context.Background(), meta, payload)
}

// WriteContext uploads a camera media chunk to the host stream with a context.
func (s *CameraMediaStream) WriteContext(ctx context.Context, meta CameraMediaChunkMetadata, payload []byte) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}

	if s == nil || s.handle == 0 {
		return errCameraMediaStreamNotInitialized
	}

	metaJSON, err := json.Marshal(meta)
	if err != nil {
		return err
	}

	res := hostCameraMediaWrite(
		s.handle,
		ptrFromBytes(metaJSON),
		uint32(len(metaJSON)),
		ptrFromBytes(payload),
		uint32(len(payload)),
	)

	return hostErr(res, "camera_media_write")
}

// Heartbeat renews the host stream lease.
func (s *CameraMediaStream) Heartbeat(meta CameraMediaHeartbeat) error {
	return s.HeartbeatContext(context.Background(), meta)
}

// HeartbeatContext renews the host stream lease with a context.
func (s *CameraMediaStream) HeartbeatContext(ctx context.Context, meta CameraMediaHeartbeat) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}

	if s == nil || s.handle == 0 {
		return errCameraMediaStreamNotInitialized
	}

	metaJSON, err := json.Marshal(meta)
	if err != nil {
		return err
	}

	res := hostCameraMediaHeartbeat(s.handle, ptrFromBytes(metaJSON), uint32(len(metaJSON)))
	return hostErr(res, "camera_media_heartbeat")
}

// Close closes the host camera media stream.
func (s *CameraMediaStream) Close(reason string) error {
	if s == nil || s.handle == 0 {
		return nil
	}

	reasonBytes := []byte(reason)
	res := hostCameraMediaClose(s.handle, ptrFromBytes(reasonBytes), uint32(len(reasonBytes)))
	s.handle = 0

	return hostErr(res, "camera_media_close")
}
