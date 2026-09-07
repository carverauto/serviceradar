package sdk

import (
	"context"
	"encoding/json"
	"errors"
)

const MaxArtifactCommitResponseBytes uint32 = 64 * 1024

var errArtifactStreamNotInitialized = errors.New("artifact stream not initialized")

// ArtifactOpenRequest describes a gateway-brokered object staging stream.
type ArtifactOpenRequest struct {
	ObjectKey   string            `json:"object_key"`
	ContentType string            `json:"content_type,omitempty"`
	SHA256      string            `json:"sha256,omitempty"`
	SizeBytes   int64             `json:"size_bytes,omitempty"`
	Attributes  map[string]string `json:"attributes,omitempty"`
}

// ArtifactWriteMetadata describes one chunk in an artifact stream.
type ArtifactWriteMetadata struct {
	Index int64 `json:"index,omitempty"`
	Final bool  `json:"final,omitempty"`
}

// ArtifactCommitRequest provides optional final verification values.
type ArtifactCommitRequest struct {
	SHA256    string `json:"sha256,omitempty"`
	SizeBytes int64  `json:"size_bytes,omitempty"`
}

// ArtifactCommitResponse is the object provenance returned by the host runtime.
type ArtifactCommitResponse struct {
	ObjectKey   string            `json:"object_key"`
	ContentType string            `json:"content_type,omitempty"`
	SHA256      string            `json:"sha256,omitempty"`
	SizeBytes   int64             `json:"size_bytes,omitempty"`
	Attributes  map[string]string `json:"attributes,omitempty"`
}

// ArtifactStream wraps a host-managed, agent-gateway-mediated artifact upload.
type ArtifactStream struct {
	handle uint32
}

// OpenArtifactStream opens a gateway-brokered artifact staging stream.
func OpenArtifactStream(req ArtifactOpenRequest) (*ArtifactStream, error) {
	return OpenArtifactStreamContext(context.Background(), req)
}

// OpenArtifactStreamContext opens a gateway-brokered artifact stream with context preflight.
func OpenArtifactStreamContext(ctx context.Context, req ArtifactOpenRequest) (*ArtifactStream, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	res := hostArtifactOpen(ptrFromBytes(payload), uint32(len(payload)))
	if res < 0 {
		return nil, hostErr(res, "artifact_open")
	}

	return &ArtifactStream{handle: uint32(res)}, nil
}

// Handle returns the host stream handle when the stream is open.
func (s *ArtifactStream) Handle() uint32 {
	if s == nil {
		return 0
	}

	return s.handle
}

// Write sends a payload chunk without explicit chunk metadata.
func (s *ArtifactStream) Write(payload []byte) (int, error) {
	return s.WriteChunk(context.Background(), ArtifactWriteMetadata{}, payload)
}

// WriteChunk sends one payload chunk with optional index/final metadata.
func (s *ArtifactStream) WriteChunk(ctx context.Context, meta ArtifactWriteMetadata, payload []byte) (int, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
	}
	if s == nil || s.handle == 0 {
		return 0, errArtifactStreamNotInitialized
	}

	metaJSON, err := json.Marshal(meta)
	if err != nil {
		return 0, err
	}
	res := hostArtifactWrite(
		s.handle,
		ptrFromBytes(metaJSON),
		uint32(len(metaJSON)),
		ptrFromBytes(payload),
		uint32(len(payload)),
	)
	if res < 0 {
		return 0, hostErr(res, "artifact_write")
	}

	return int(res), nil
}

// Commit verifies and publishes the staged artifact through the host runtime.
func (s *ArtifactStream) Commit(req ArtifactCommitRequest) (*ArtifactCommitResponse, error) {
	return s.CommitContext(context.Background(), req)
}

// CommitContext verifies and publishes the staged artifact with context preflight.
func (s *ArtifactStream) CommitContext(ctx context.Context, req ArtifactCommitRequest) (*ArtifactCommitResponse, error) {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
	if s == nil || s.handle == 0 {
		return nil, errArtifactStreamNotInitialized
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	respBuf := make([]byte, MaxArtifactCommitResponseBytes)
	res := hostArtifactCommit(
		s.handle,
		ptrFromBytes(payload),
		uint32(len(payload)),
		ptrFromBytes(respBuf),
		uint32(len(respBuf)),
	)
	if res < 0 {
		return nil, hostErr(res, "artifact_commit")
	}
	s.handle = 0

	var response ArtifactCommitResponse
	if err := json.Unmarshal(respBuf[:res], &response); err != nil {
		return nil, err
	}

	return &response, nil
}

// Abort discards an uncommitted artifact stream.
func (s *ArtifactStream) Abort() error {
	if s == nil || s.handle == 0 {
		return errArtifactStreamNotInitialized
	}
	res := hostArtifactAbort(s.handle)
	if res >= 0 {
		s.handle = 0
	}

	return hostErr(res, "artifact_abort")
}
