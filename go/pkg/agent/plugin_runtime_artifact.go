package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/tetratelabs/wazero/api"
)

const pluginArtifactDefaultContentType = "application/octet-stream"

var (
	errPluginArtifactUploaderUnavailable = errors.New("artifact uploader unavailable")
	errPluginArtifactDigestMismatch      = errors.New("artifact digest mismatch")
	errPluginArtifactSizeMismatch        = errors.New("artifact size mismatch")
	errPluginArtifactInvalidObjectKey    = errors.New("invalid artifact object key")
	errPluginArtifactOpenLimitExceeded   = errors.New("artifact open stream limit exceeded")
	errPluginArtifactUnexpectedChunk     = errors.New("unexpected artifact chunk index")
	errPluginArtifactShortWrite          = errors.New("short artifact write")
	pluginArtifactKeyPattern             = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
)

// PluginArtifactUploader is the trusted host-side boundary for Wasm artifact staging.
// Implementations must forward bytes through the agent-gateway API; plugins never
// receive direct object-store credentials or endpoints.
type PluginArtifactUploader interface {
	UploadPluginArtifact(context.Context, PluginArtifactUploadRequest) (PluginArtifactUploadResponse, error)
}

// PluginArtifactUploadRequest carries the committed artifact to the gateway uploader.
type PluginArtifactUploadRequest struct {
	AssignmentID string
	PluginID     string
	PluginName   string
	Source       string
	DownloadURL  string
	ObjectKey    string
	ContentType  string
	SHA256       string
	Size         int64
	FilePath     string
	Attributes   map[string]string
}

// PluginArtifactUploadResponse is returned to the Wasm plugin after gateway commit.
type PluginArtifactUploadResponse struct {
	ObjectKey   string            `json:"object_key"`
	ContentType string            `json:"content_type,omitempty"`
	SHA256      string            `json:"sha256,omitempty"`
	SizeBytes   int64             `json:"size_bytes,omitempty"`
	Attributes  map[string]string `json:"attributes,omitempty"`
}

type pluginArtifactOpenRequest struct {
	ObjectKey   string            `json:"object_key"`
	ContentType string            `json:"content_type,omitempty"`
	SHA256      string            `json:"sha256,omitempty"`
	SizeBytes   int64             `json:"size_bytes,omitempty"`
	Attributes  map[string]string `json:"attributes,omitempty"`
}

type pluginArtifactChunkMetadata struct {
	Index int64 `json:"index,omitempty"`
	Final bool  `json:"final,omitempty"`
}

type pluginArtifactCommitRequest struct {
	SHA256    string `json:"sha256,omitempty"`
	SizeBytes int64  `json:"size_bytes,omitempty"`
}

type pluginArtifactStream struct {
	objectKey      string
	contentType    string
	expectedSHA256 string
	expectedSize   int64
	attributes     map[string]string
	path           string
	file           *os.File
	hash           hash.Hash
	size           int64
	nextChunkIndex int64
	closed         bool
}

func (e *pluginExecution) hostArtifactOpen(_ context.Context, mod api.Module, reqPtr, reqLen uint32) int32 {
	if !e.hasCapability(pluginCapabilityArtifactStaging) {
		return pluginErrDenied
	}
	if e.manager.artifactUploaderResolver() == nil {
		return pluginErrNotFound
	}

	request, code := decodeArtifactOpenRequest(mod, reqPtr, reqLen)
	if code != pluginErrOK {
		return code
	}

	stream, err := e.newArtifactStream(request)
	if err != nil {
		return pluginArtifactErrorCode(err)
	}

	handle := e.storeArtifactStream(stream)
	if handle == 0 {
		_ = stream.abort()
		return pluginErrTooLarge
	}

	return int32(handle)
}

func (e *pluginExecution) hostArtifactWrite(
	_ context.Context,
	mod api.Module,
	handle, metaPtr, metaLen, payloadPtr, payloadLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityArtifactStaging) {
		return pluginErrDenied
	}

	payload, ok := readMemory(mod, payloadPtr, payloadLen)
	if !ok {
		return pluginErrInvalid
	}
	if len(payload) == 0 {
		return pluginErrInvalid
	}
	if len(payload) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	metadata, code := decodeArtifactChunkMetadata(mod, metaPtr, metaLen)
	if code != pluginErrOK {
		return code
	}

	stream := e.getArtifactStream(handle)
	if stream == nil {
		return pluginErrBadHandle
	}
	if err := stream.write(payload, metadata); err != nil {
		return pluginArtifactErrorCode(err)
	}

	return int32(len(payload))
}

func (e *pluginExecution) hostArtifactCommit(
	ctx context.Context,
	mod api.Module,
	handle, reqPtr, reqLen, respPtr, respLen uint32,
) int32 {
	if !e.hasCapability(pluginCapabilityArtifactStaging) {
		return pluginErrDenied
	}

	request, code := decodeArtifactCommitRequest(mod, reqPtr, reqLen)
	if code != pluginErrOK {
		return code
	}

	stream := e.deleteArtifactStream(handle)
	if stream == nil {
		return pluginErrBadHandle
	}
	defer stream.cleanup()

	if err := stream.close(); err != nil {
		return pluginArtifactErrorCode(err)
	}
	if err := stream.verify(request); err != nil {
		return pluginArtifactErrorCode(err)
	}

	uploader := e.manager.artifactUploaderResolver()
	if uploader == nil {
		return pluginErrNotFound
	}

	downloadURL, _ := e.assignment.downloadCredentials()
	response, err := uploader.UploadPluginArtifact(ctx, PluginArtifactUploadRequest{
		AssignmentID: e.assignment.AssignmentID,
		PluginID:     e.assignment.PluginID,
		PluginName:   e.assignment.Name,
		Source:       "wasm-plugin",
		DownloadURL:  downloadURL,
		ObjectKey:    stream.objectKey,
		ContentType:  stream.contentType,
		SHA256:       stream.actualSHA256(),
		Size:         stream.size,
		FilePath:     stream.path,
		Attributes:   clonePluginStringMap(stream.attributes),
	})
	if err != nil {
		return pluginArtifactErrorCode(err)
	}

	payload, err := json.Marshal(response)
	if err != nil {
		return pluginErrInternal
	}
	if len(payload) > int(respLen) {
		return pluginErrTooLarge
	}
	if !writeMemory(mod, respPtr, payload) {
		return pluginErrInvalid
	}

	return int32(len(payload))
}

func (e *pluginExecution) hostArtifactAbort(_ context.Context, _ api.Module, handle uint32) int32 {
	if !e.hasCapability(pluginCapabilityArtifactStaging) {
		return pluginErrDenied
	}

	stream := e.deleteArtifactStream(handle)
	if stream == nil {
		return pluginErrBadHandle
	}
	if err := stream.abort(); err != nil {
		return pluginArtifactErrorCode(err)
	}

	return pluginErrOK
}

func decodeArtifactOpenRequest(mod api.Module, ptr, size uint32) (pluginArtifactOpenRequest, int32) {
	var request pluginArtifactOpenRequest
	if size == 0 {
		return request, pluginErrInvalid
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return request, pluginErrInvalid
	}
	if len(raw) > pluginMaxPayloadBytes {
		return request, pluginErrTooLarge
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, pluginErrInvalid
	}
	request.ObjectKey = strings.TrimSpace(request.ObjectKey)
	request.ContentType = strings.TrimSpace(request.ContentType)
	request.SHA256 = strings.ToLower(strings.TrimSpace(request.SHA256))

	if !validPluginArtifactObjectKey(request.ObjectKey) {
		return request, pluginErrInvalid
	}
	if request.SHA256 != "" && !validSHA256(request.SHA256) {
		return request, pluginErrInvalid
	}
	if request.SizeBytes < 0 {
		return request, pluginErrInvalid
	}
	if request.ContentType == "" {
		request.ContentType = pluginArtifactDefaultContentType
	}

	return request, pluginErrOK
}

func decodeArtifactChunkMetadata(mod api.Module, ptr, size uint32) (pluginArtifactChunkMetadata, int32) {
	var metadata pluginArtifactChunkMetadata
	if size == 0 {
		return metadata, pluginErrOK
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return metadata, pluginErrInvalid
	}
	if len(raw) > pluginMaxPayloadBytes {
		return metadata, pluginErrTooLarge
	}
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return metadata, pluginErrInvalid
	}
	if metadata.Index < 0 {
		return metadata, pluginErrInvalid
	}

	return metadata, pluginErrOK
}

func decodeArtifactCommitRequest(mod api.Module, ptr, size uint32) (pluginArtifactCommitRequest, int32) {
	var request pluginArtifactCommitRequest
	if size == 0 {
		return request, pluginErrOK
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return request, pluginErrInvalid
	}
	if len(raw) > pluginMaxPayloadBytes {
		return request, pluginErrTooLarge
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, pluginErrInvalid
	}
	request.SHA256 = strings.ToLower(strings.TrimSpace(request.SHA256))
	if request.SHA256 != "" && !validSHA256(request.SHA256) {
		return request, pluginErrInvalid
	}
	if request.SizeBytes < 0 {
		return request, pluginErrInvalid
	}

	return request, pluginErrOK
}

func (e *pluginExecution) newArtifactStream(request pluginArtifactOpenRequest) (*pluginArtifactStream, error) {
	if e == nil || e.manager == nil {
		return nil, errPluginArtifactUploaderUnavailable
	}

	dir := filepath.Join(e.manager.localStoreDir, "plugin-artifacts")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}

	file, err := os.CreateTemp(dir, "artifact-*.tmp")
	if err != nil {
		return nil, err
	}

	return &pluginArtifactStream{
		objectKey:      request.ObjectKey,
		contentType:    request.ContentType,
		expectedSHA256: request.SHA256,
		expectedSize:   request.SizeBytes,
		attributes:     clonePluginStringMap(request.Attributes),
		path:           file.Name(),
		file:           file,
		hash:           sha256.New(),
	}, nil
}

func (e *pluginExecution) storeArtifactStream(stream *pluginArtifactStream) uint32 {
	e.mu.Lock()
	defer e.mu.Unlock()

	if len(e.artifactStreams) >= e.maxOpenArtifactStreams() {
		return 0
	}

	handle := e.nextHandle
	e.nextHandle++
	e.artifactStreams[handle] = stream

	return handle
}

func (e *pluginExecution) maxOpenArtifactStreams() int {
	max := e.assignment.Resources.MaxOpenConnections
	if max <= 0 {
		return 4
	}
	return max
}

func (e *pluginExecution) getArtifactStream(handle uint32) *pluginArtifactStream {
	e.mu.Lock()
	defer e.mu.Unlock()

	return e.artifactStreams[handle]
}

func (e *pluginExecution) deleteArtifactStream(handle uint32) *pluginArtifactStream {
	e.mu.Lock()
	defer e.mu.Unlock()

	stream := e.artifactStreams[handle]
	delete(e.artifactStreams, handle)

	return stream
}

func (m *PluginManager) artifactUploaderResolver() PluginArtifactUploader {
	if m == nil {
		return nil
	}

	m.artifactMu.Lock()
	defer m.artifactMu.Unlock()

	return m.artifactUploader
}

func (s *pluginArtifactStream) write(payload []byte, metadata pluginArtifactChunkMetadata) error {
	if s == nil || s.file == nil || s.closed {
		return errPluginArtifactUploaderUnavailable
	}
	if metadata.Index > 0 && metadata.Index != s.nextChunkIndex {
		return fmt.Errorf("%w: got %d want %d", errPluginArtifactUnexpectedChunk, metadata.Index, s.nextChunkIndex)
	}

	n, err := s.file.Write(payload)
	if err != nil {
		return err
	}
	if n != len(payload) {
		return fmt.Errorf("%w: %d of %d", errPluginArtifactShortWrite, n, len(payload))
	}
	if _, err := s.hash.Write(payload); err != nil {
		return err
	}
	s.size += int64(n)
	s.nextChunkIndex++

	if s.expectedSize > 0 && s.size > s.expectedSize {
		return errPluginArtifactSizeMismatch
	}

	return nil
}

func (s *pluginArtifactStream) close() error {
	if s == nil || s.file == nil || s.closed {
		return nil
	}

	s.closed = true
	return s.file.Close()
}

func (s *pluginArtifactStream) verify(request pluginArtifactCommitRequest) error {
	expectedSHA := s.expectedSHA256
	if request.SHA256 != "" {
		expectedSHA = request.SHA256
	}
	if expectedSHA != "" && expectedSHA != s.actualSHA256() {
		return errPluginArtifactDigestMismatch
	}

	expectedSize := s.expectedSize
	if request.SizeBytes > 0 {
		expectedSize = request.SizeBytes
	}
	if expectedSize > 0 && expectedSize != s.size {
		return errPluginArtifactSizeMismatch
	}

	return nil
}

func (s *pluginArtifactStream) actualSHA256() string {
	if s == nil || s.hash == nil {
		return ""
	}
	return hex.EncodeToString(s.hash.Sum(nil))
}

func (s *pluginArtifactStream) abort() error {
	if s == nil {
		return nil
	}
	if s.file != nil && !s.closed {
		_ = s.file.Close()
		s.closed = true
	}
	return os.Remove(s.path)
}

func (s *pluginArtifactStream) cleanup() {
	if s == nil || s.path == "" {
		return
	}
	_ = os.Remove(s.path)
}

func validPluginArtifactObjectKey(key string) bool {
	if key == "" || strings.HasPrefix(key, "/") || strings.Contains(key, "..") ||
		strings.Contains(key, "//") || !pluginArtifactKeyPattern.MatchString(key) {
		return false
	}

	for _, segment := range strings.Split(key, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}

	return true
}

func validSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, ch := range value {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return false
		}
	}
	return true
}

func pluginArtifactErrorCode(err error) int32 {
	switch {
	case err == nil:
		return pluginErrOK
	case errors.Is(err, errPluginArtifactOpenLimitExceeded):
		return pluginErrTooLarge
	case errors.Is(err, errPluginArtifactInvalidObjectKey),
		errors.Is(err, errPluginArtifactDigestMismatch),
		errors.Is(err, errPluginArtifactSizeMismatch):
		return pluginErrInvalid
	case errors.Is(err, errPluginArtifactUploaderUnavailable):
		return pluginErrNotFound
	default:
		return pluginErrInternal
	}
}

func clonePluginStringMap(input map[string]string) map[string]string {
	if len(input) == 0 {
		return nil
	}

	output := make(map[string]string, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func pluginArtifactUploadURL(downloadURL string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(downloadURL))
	if err != nil {
		return "", err
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return "", errPluginArtifactUploaderUnavailable
	}

	parsed.Path = "/artifacts/agent-artifacts/upload"
	parsed.RawQuery = ""
	parsed.Fragment = ""

	return parsed.String(), nil
}
