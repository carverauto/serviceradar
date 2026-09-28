//go:build !tinygo

package sdk

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"hash"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	localArtifactDefaultContentType = "application/octet-stream"
	localArtifactMaxOpenStreams     = 8
)

var localArtifactKeyPattern = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)

// LocalHostArtifact describes one artifact committed during a local run.
type LocalHostArtifact struct {
	ObjectKey   string
	Path        string
	ContentType string
	SHA256      string
	SizeBytes   int64
	Attributes  map[string]string
}

type localArtifacts struct {
	next      uint32
	open      map[uint32]*localArtifactStream
	committed []LocalHostArtifact
}

type localArtifactStream struct {
	request   ArtifactOpenRequest
	file      *os.File
	hash      hash.Hash
	size      int64
	nextIndex int64
}

// artifactOpen mirrors the agent host: the object key, digest and size are
// validated up front and the body is staged in a temporary file.
func (h *localHostExecution) artifactOpen(encoded []byte) int32 {
	if h == nil || strings.TrimSpace(h.artifactDir) == "" {
		return hostErrNotFound
	}
	if len(encoded) == 0 {
		return hostErrInvalid
	}
	if len(encoded) > MaxPayloadBytes {
		return hostErrTooLarge
	}

	var request ArtifactOpenRequest
	if err := json.Unmarshal(encoded, &request); err != nil {
		return hostErrInvalid
	}
	request.ObjectKey = strings.TrimSpace(request.ObjectKey)
	request.ContentType = strings.TrimSpace(request.ContentType)
	request.SHA256 = strings.ToLower(strings.TrimSpace(request.SHA256))
	if !validLocalArtifactKey(request.ObjectKey) {
		return hostErrInvalid
	}
	if request.SHA256 != "" && !validLocalSHA256(request.SHA256) {
		return hostErrInvalid
	}
	if request.SizeBytes < 0 {
		return hostErrInvalid
	}
	if request.ContentType == "" {
		request.ContentType = localArtifactDefaultContentType
	}
	if _, _, code := encodeLocalCommitResponse(request, strings.Repeat("f", 64), math.MaxInt64, int(MaxArtifactCommitResponseBytes)); code != hostErrOK {
		return code
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.artifacts.open) >= localArtifactMaxOpenStreams {
		return hostErrTooLarge
	}

	if err := os.MkdirAll(h.artifactDir, 0o700); err != nil {
		return hostErrInternal
	}
	file, err := os.CreateTemp(h.artifactDir, ".artifact-*.tmp")
	if err != nil {
		return hostErrInternal
	}

	if h.artifacts.open == nil {
		h.artifacts.open = make(map[uint32]*localArtifactStream)
	}
	h.artifacts.next++
	handle := h.artifacts.next
	h.artifacts.open[handle] = &localArtifactStream{request: request, file: file, hash: sha256.New()}
	return int32(handle)
}

func (h *localHostExecution) artifactWrite(handle uint32, meta, payload []byte) int32 {
	if len(payload) == 0 {
		return hostErrInvalid
	}
	if len(payload) > MaxPayloadBytes {
		return hostErrTooLarge
	}
	var metadata ArtifactWriteMetadata
	if len(meta) > 0 {
		if err := json.Unmarshal(meta, &metadata); err != nil {
			return hostErrInvalid
		}
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	stream := h.artifacts.open[handle]
	if stream == nil {
		return hostErrBadHandle
	}
	if metadata.Index > 0 && metadata.Index != stream.nextIndex {
		return hostErrInvalid
	}
	if _, err := stream.file.Write(payload); err != nil {
		return hostErrInternal
	}
	_, _ = stream.hash.Write(payload)
	stream.size += int64(len(payload))
	stream.nextIndex++
	if stream.request.SizeBytes > 0 && stream.size > stream.request.SizeBytes {
		return hostErrInvalid
	}
	return int32(len(payload))
}

func (h *localHostExecution) artifactCommit(handle uint32, encoded, responseBuf []byte) int32 {
	var request ArtifactCommitRequest
	if len(encoded) > 0 {
		if err := json.Unmarshal(encoded, &request); err != nil {
			return hostErrInvalid
		}
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	stream := h.artifacts.open[handle]
	if stream == nil {
		return hostErrBadHandle
	}
	delete(h.artifacts.open, handle)

	actualSHA := hex.EncodeToString(stream.hash.Sum(nil))
	if code := stream.verify(request, actualSHA); code != hostErrOK {
		stream.discard()
		return code
	}
	if err := stream.file.Close(); err != nil {
		stream.discard()
		return hostErrInternal
	}

	response, payload, code := encodeLocalCommitResponse(stream.request, actualSHA, stream.size, len(responseBuf))
	if code != hostErrOK {
		stream.discard()
		return code
	}

	target := filepath.Join(h.artifactDir, filepath.FromSlash(stream.request.ObjectKey))
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		stream.discard()
		return hostErrInternal
	}
	if err := os.Chmod(stream.file.Name(), 0o600); err != nil {
		stream.discard()
		return hostErrInternal
	}
	if err := os.Rename(stream.file.Name(), target); err != nil {
		stream.discard()
		return hostErrInternal
	}
	copy(responseBuf, payload)

	h.artifacts.committed = append(h.artifacts.committed, LocalHostArtifact{
		ObjectKey:   response.ObjectKey,
		Path:        target,
		ContentType: response.ContentType,
		SHA256:      response.SHA256,
		SizeBytes:   response.SizeBytes,
		Attributes:  cloneLocalStringMap(response.Attributes),
	})
	return int32(len(payload))
}

func encodeLocalCommitResponse(request ArtifactOpenRequest, sha string, size int64, limit int) (ArtifactCommitResponse, []byte, int32) {
	response := ArtifactCommitResponse{
		ObjectKey:   request.ObjectKey,
		ContentType: request.ContentType,
		SHA256:      sha,
		SizeBytes:   size,
		Attributes:  cloneLocalStringMap(request.Attributes),
	}
	payload, err := json.Marshal(response)
	if err != nil {
		return response, nil, hostErrInternal
	}
	if len(payload) > limit {
		return response, nil, hostErrTooLarge
	}
	return response, payload, hostErrOK
}

func (h *localHostExecution) artifactAbort(handle uint32) int32 {
	h.mu.Lock()
	defer h.mu.Unlock()
	stream := h.artifacts.open[handle]
	if stream == nil {
		return hostErrBadHandle
	}
	delete(h.artifacts.open, handle)
	stream.discard()
	return hostErrOK
}

// abortOpenArtifacts removes staging files a plugin opened but never
// committed or aborted, so a failed run leaves nothing partial behind.
func (h *localHostExecution) abortOpenArtifacts() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for handle, stream := range h.artifacts.open {
		stream.discard()
		delete(h.artifacts.open, handle)
	}
}

func (s *localArtifactStream) verify(request ArtifactCommitRequest, actualSHA string) int32 {
	expectedSHA := s.request.SHA256
	if value := strings.ToLower(strings.TrimSpace(request.SHA256)); value != "" {
		expectedSHA = value
	}
	if expectedSHA != "" && expectedSHA != actualSHA {
		return hostErrInvalid
	}
	expectedSize := s.request.SizeBytes
	if request.SizeBytes > 0 {
		expectedSize = request.SizeBytes
	}
	if expectedSize > 0 && expectedSize != s.size {
		return hostErrInvalid
	}
	return hostErrOK
}

func (s *localArtifactStream) discard() {
	_ = s.file.Close()
	_ = os.Remove(s.file.Name())
}

func validLocalArtifactKey(key string) bool {
	if key == "" || strings.HasPrefix(key, "/") || strings.Contains(key, "..") ||
		strings.Contains(key, "//") || !localArtifactKeyPattern.MatchString(key) {
		return false
	}
	for _, segment := range strings.Split(key, "/") {
		if segment == "" || segment == "." {
			return false
		}
	}
	return true
}

func validLocalSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func cloneLocalStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	cloned := make(map[string]string, len(values))
	for key, value := range values {
		cloned[key] = value
	}
	return cloned
}
