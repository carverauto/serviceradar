/*
 * Copyright 2025 Carver Automation Corporation.
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
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tftp "github.com/pin/tftp/v3"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/rs/zerolog"
)

const (
	defaultTFTPPort        = 69
	defaultMaxFileSize     = 100 * 1024 * 1024 // 100MB
	defaultSessionTimeout  = 5 * time.Minute
	defaultStagingDir      = "/var/lib/serviceradar/tftp-staging"
	defaultStagingTTL      = 1 * time.Hour
	stagingCleanupInterval = 5 * time.Minute
	tftpProgressIntervalRx = time.Second
	tftpHeartbeatInterval  = 5 * time.Second
)

// TFTPSessionMode represents the mode of a TFTP session.
type TFTPSessionMode string

const (
	TFTPModeReceive TFTPSessionMode = "receive"
	TFTPModeServe   TFTPSessionMode = "serve"
)

// TFTPSession holds the state for an active TFTP session.
type TFTPSession struct {
	mu               sync.RWMutex
	SessionID        string
	Mode             TFTPSessionMode
	ExpectedFilename string
	MaxFileSize      int64
	TimeoutDuration  time.Duration
	BindAddress      string
	Port             int
	ContentHash      string // expected hash for serve mode
	ImagePath        string // local path to staged image for serve mode

	// Runtime state
	server        *tftp.Server
	bytesTransfer int64
	started       time.Time
	cancel        context.CancelFunc
	done          chan struct{}
}

// TFTPService implements the Service interface for TFTP server functionality.
type TFTPService struct {
	mu         sync.RWMutex
	logger     zerolog.Logger
	stagingDir string
	stagingTTL time.Duration
	session    *TFTPSession
	stopClean  chan struct{}

	// Callback for reporting progress and results back to the command bus
	onProgress func(sessionID string, bytesTransferred int64, message string)
	onResult   func(sessionID string, success bool, message string, fileSize int64, contentHash string)
}

// NewTFTPService creates a new TFTPService.
func NewTFTPService(logger zerolog.Logger, stagingDir string) *TFTPService {
	if stagingDir == "" {
		stagingDir = defaultStagingDir
	}

	return &TFTPService{
		logger:     logger.With().Str("service", "tftp").Logger(),
		stagingDir: stagingDir,
		stagingTTL: defaultStagingTTL,
		stopClean:  make(chan struct{}),
	}
}

// SetCallbacks sets the progress and result reporting callbacks.
func (s *TFTPService) SetCallbacks(
	onProgress func(sessionID string, bytesTransferred int64, message string),
	onResult func(sessionID string, success bool, message string, fileSize int64, contentHash string),
) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.onProgress = onProgress
	s.onResult = onResult
}

// Name returns the service name.
func (s *TFTPService) Name() string {
	return "tftp"
}

// Start initializes the TFTP service and starts the staging cleanup goroutine.
func (s *TFTPService) Start(_ context.Context) error {
	s.logger.Info().Str("staging_dir", s.stagingDir).Msg("TFTP service initialized")

	if err := os.MkdirAll(s.stagingDir, 0o750); err != nil {
		return fmt.Errorf("create staging dir: %w", err)
	}

	go s.stagingCleanupLoop()

	return nil
}

// Stop shuts down any active TFTP session and the staging cleanup goroutine.
func (s *TFTPService) Stop(ctx context.Context) error {
	close(s.stopClean)

	s.mu.Lock()
	session := s.session
	s.mu.Unlock()

	if session != nil {
		return s.stopSession(ctx, session.SessionID)
	}

	return nil
}

// UpdateConfig handles dynamic config updates (no-op for TFTP).
func (s *TFTPService) UpdateConfig(_ *models.Config) error {
	return nil
}

// HasActiveSession returns true if there is an active TFTP session.
func (s *TFTPService) HasActiveSession() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return s.session != nil
}

// StartReceive starts a TFTP server in receive mode (device writes to agent).
func (s *TFTPService) StartReceive(ctx context.Context, payload tftpReceivePayload) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.session != nil {
		return fmt.Errorf("agent already has active TFTP session %s", s.session.SessionID)
	}

	port := payload.Port
	if port == 0 {
		port = defaultTFTPPort
	}

	maxFileSize := payload.MaxFileSize
	if maxFileSize == 0 {
		maxFileSize = defaultMaxFileSize
	}

	timeout := time.Duration(payload.TimeoutSeconds) * time.Second
	if timeout == 0 {
		timeout = defaultSessionTimeout
	}

	bindAddr := payload.BindAddress
	if bindAddr == "" {
		bindAddr = primaryInterfaceAddr()
	}

	session := &TFTPSession{
		SessionID:        payload.SessionID,
		Mode:             TFTPModeReceive,
		ExpectedFilename: payload.ExpectedFilename,
		MaxFileSize:      maxFileSize,
		TimeoutDuration:  timeout,
		BindAddress:      bindAddr,
		Port:             port,
		done:             make(chan struct{}),
	}

	// Create staging directory for this session
	sessionDir := filepath.Join(s.stagingDir, session.SessionID)
	if err := os.MkdirAll(sessionDir, 0o750); err != nil {
		return fmt.Errorf("create session staging dir: %w", err)
	}

	// Create TFTP server with write handler only (receive mode)
	server := tftp.NewServer(nil, s.makeWriteHandler(session))
	server.SetTimeout(5 * time.Second)
	session.server = server

	sessionCtx, cancel := context.WithTimeout(ctx, timeout)
	session.cancel = cancel
	session.started = time.Now()

	s.session = session

	// Start server in background
	go s.runServer(sessionCtx, session, bindAddr, port)

	// Start heartbeat in background
	go s.heartbeatLoop(sessionCtx, session)

	s.logger.Info().
		Str("session_id", session.SessionID).
		Str("filename", session.ExpectedFilename).
		Str("bind", fmt.Sprintf("%s:%d", bindAddr, port)).
		Dur("timeout", timeout).
		Msg("TFTP receive session started")

	return nil
}

// StartServe starts a TFTP server in serve mode (device reads from agent).
func (s *TFTPService) StartServe(ctx context.Context, payload tftpServePayload) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.session != nil {
		return fmt.Errorf("agent already has active TFTP session %s", s.session.SessionID)
	}

	// Verify the staged image exists
	imagePath := filepath.Join(s.stagingDir, payload.SessionID, payload.Filename)
	if _, err := os.Stat(imagePath); err != nil {
		return fmt.Errorf("staged image not found at %s: %w", imagePath, err)
	}

	port := payload.Port
	if port == 0 {
		port = defaultTFTPPort
	}

	timeout := time.Duration(payload.TimeoutSeconds) * time.Second
	if timeout == 0 {
		timeout = defaultSessionTimeout
	}

	bindAddr := payload.BindAddress
	if bindAddr == "" {
		bindAddr = primaryInterfaceAddr()
	}

	session := &TFTPSession{
		SessionID:        payload.SessionID,
		Mode:             TFTPModeServe,
		ExpectedFilename: payload.Filename,
		ContentHash:      payload.ContentHash,
		ImagePath:        imagePath,
		MaxFileSize:      payload.FileSize,
		TimeoutDuration:  timeout,
		BindAddress:      bindAddr,
		Port:             port,
		done:             make(chan struct{}),
	}

	// Create TFTP server with read handler only (serve mode)
	server := tftp.NewServer(s.makeReadHandler(session), nil)
	server.SetTimeout(5 * time.Second)
	session.server = server

	sessionCtx, cancel := context.WithTimeout(ctx, timeout)
	session.cancel = cancel
	session.started = time.Now()

	s.session = session

	// Start server in background
	go s.runServer(sessionCtx, session, bindAddr, port)

	// Start heartbeat in background
	go s.heartbeatLoop(sessionCtx, session)

	s.logger.Info().
		Str("session_id", session.SessionID).
		Str("filename", session.ExpectedFilename).
		Str("image_path", imagePath).
		Str("bind", fmt.Sprintf("%s:%d", bindAddr, port)).
		Dur("timeout", timeout).
		Msg("TFTP serve session started")

	return nil
}

// stopSession stops the active TFTP session.
func (s *TFTPService) stopSession(_ context.Context, sessionID string) error {
	s.mu.Lock()
	session := s.session
	s.mu.Unlock()

	if session == nil {
		return nil
	}

	if session.SessionID != sessionID {
		return fmt.Errorf("session %s not found (active: %s)", sessionID, session.SessionID)
	}

	s.logger.Info().Str("session_id", sessionID).Msg("stopping TFTP session")

	// Cancel the session context, which will trigger server shutdown
	if session.cancel != nil {
		session.cancel()
	}

	// Wait for server goroutine to finish
	select {
	case <-session.done:
	case <-time.After(10 * time.Second):
		s.logger.Warn().Str("session_id", sessionID).Msg("timeout waiting for TFTP session shutdown")
	}

	s.cleanupSession(session)

	return nil
}

// runServer runs the TFTP server and blocks until context is cancelled or server shuts down.
func (s *TFTPService) runServer(ctx context.Context, session *TFTPSession, bindAddr string, port int) {
	defer close(session.done)
	defer s.cleanupSession(session)

	addr := fmt.Sprintf("%s:%d", bindAddr, port)

	conn, err := net.ListenPacket("udp", addr)
	if err != nil {
		s.logger.Error().Err(err).Str("addr", addr).Msg("failed to bind TFTP server")
		s.reportResult(session.SessionID, false, fmt.Sprintf("bind failed: %v", err), 0, "")

		return
	}

	// Shutdown server when context expires
	go func() {
		<-ctx.Done()
		session.server.Shutdown()

		// Also close the connection to unblock Serve()
		conn.Close()
	}()

	s.logger.Info().Str("addr", addr).Str("session_id", session.SessionID).Msg("TFTP server listening")

	if err := session.server.Serve(conn); err != nil {
		// Only log as error if context wasn't cancelled (expected shutdown)
		if ctx.Err() == nil {
			s.logger.Error().Err(err).Str("session_id", session.SessionID).Msg("TFTP server error")
		}
	}
}

// makeWriteHandler creates a TFTP write handler for receive mode.
func (s *TFTPService) makeWriteHandler(session *TFTPSession) func(string, io.WriterTo) error {
	return func(filename string, wt io.WriterTo) error {
		// Validate filename
		if !s.isFilenameAllowed(filename, session.ExpectedFilename) {
			s.logger.Warn().
				Str("session_id", session.SessionID).
				Str("requested", filename).
				Str("expected", session.ExpectedFilename).
				Msg("TFTP write request rejected: filename mismatch")

			return fmt.Errorf("filename not allowed: %s", filename)
		}

		s.logger.Info().
			Str("session_id", session.SessionID).
			Str("filename", filename).
			Msg("TFTP receive transfer started")

		// Write to staging file with size limit enforcement
		outputPath := filepath.Join(s.stagingDir, session.SessionID, filepath.Base(filename))
		hash, bytesWritten, err := s.receiveFile(session, wt, outputPath)

		if err != nil {
			s.logger.Error().Err(err).Str("session_id", session.SessionID).Msg("TFTP receive failed")
			s.reportResult(session.SessionID, false, fmt.Sprintf("receive failed: %v", err), bytesWritten, "")

			return err
		}

		s.logger.Info().
			Str("session_id", session.SessionID).
			Int64("bytes", bytesWritten).
			Str("hash", hash).
			Msg("TFTP receive transfer completed")

		s.reportResult(session.SessionID, true, "transfer complete", bytesWritten, hash)

		// Stop the session after successful transfer (single-use)
		go func() {
			if session.cancel != nil {
				session.cancel()
			}
		}()

		return nil
	}
}

// makeReadHandler creates a TFTP read handler for serve mode.
func (s *TFTPService) makeReadHandler(session *TFTPSession) func(string, io.ReaderFrom) error {
	return func(filename string, rf io.ReaderFrom) error {
		// Validate filename
		if !s.isFilenameAllowed(filename, session.ExpectedFilename) {
			s.logger.Warn().
				Str("session_id", session.SessionID).
				Str("requested", filename).
				Str("expected", session.ExpectedFilename).
				Msg("TFTP read request rejected: filename mismatch")

			return fmt.Errorf("filename not allowed: %s", filename)
		}

		s.logger.Info().
			Str("session_id", session.SessionID).
			Str("filename", filename).
			Str("image_path", session.ImagePath).
			Msg("TFTP serve transfer started")

		file, err := os.Open(session.ImagePath)
		if err != nil {
			s.reportResult(session.SessionID, false, fmt.Sprintf("open image failed: %v", err), 0, "")
			return fmt.Errorf("open staged image: %w", err)
		}
		defer file.Close()

		// Set transfer size if available
		if fi, statErr := file.Stat(); statErr == nil {
			if ot, ok := rf.(tftp.OutgoingTransfer); ok {
				ot.SetSize(fi.Size())
			}
		}

		n, err := rf.ReadFrom(file)
		if err != nil {
			s.logger.Error().Err(err).Str("session_id", session.SessionID).Msg("TFTP serve failed")
			s.reportResult(session.SessionID, false, fmt.Sprintf("serve failed: %v", err), n, "")

			return err
		}

		s.logger.Info().
			Str("session_id", session.SessionID).
			Int64("bytes", n).
			Msg("TFTP serve transfer completed")

		s.reportResult(session.SessionID, true, "transfer complete", n, session.ContentHash)

		// Stop session after successful transfer (single-use)
		go func() {
			if session.cancel != nil {
				session.cancel()
			}
		}()

		return nil
	}
}

// receiveFile writes TFTP data to a file with size limit and SHA-256 computation.
func (s *TFTPService) receiveFile(session *TFTPSession, wt io.WriterTo, outputPath string) (string, int64, error) {
	file, err := os.OpenFile(outputPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o640)
	if err != nil {
		return "", 0, fmt.Errorf("create output file: %w", err)
	}
	defer file.Close()

	hasher := sha256.New()
	limitWriter := &limitedWriter{
		w:     io.MultiWriter(file, hasher),
		limit: session.MaxFileSize,
	}

	// Track progress in a goroutine — use a local stop channel so it
	// terminates promptly when the transfer finishes, rather than waiting
	// for the entire server to shut down.
	stopProgress := make(chan struct{})

	go func() {
		ticker := time.NewTicker(tftpProgressIntervalRx)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				s.reportProgress(session.SessionID, limitWriter.written, "receiving")
			case <-stopProgress:
				return
			}
		}
	}()

	n, err := wt.WriteTo(limitWriter)
	close(stopProgress)

	if err != nil {
		if errors.Is(err, errFileSizeLimitExceeded) {
			return "", n, fmt.Errorf("file exceeds maximum size of %d bytes", session.MaxFileSize)
		}

		return "", n, fmt.Errorf("write: %w", err)
	}

	hash := hex.EncodeToString(hasher.Sum(nil))

	return hash, n, nil
}

// isFilenameAllowed checks if a filename matches the expected pattern.
func (s *TFTPService) isFilenameAllowed(requested, expected string) bool {
	// Reject null bytes and control characters
	for _, c := range requested {
		if c == 0 || (c < 32 && c != '\t') || c == 127 {
			return false
		}
	}

	// Reject path traversal attempts
	if strings.Contains(requested, "..") ||
		strings.Contains(requested, "/") ||
		strings.Contains(requested, "\\") {
		return false
	}

	// Clean the filename
	cleaned := filepath.Base(requested)
	if cleaned != requested {
		return false
	}

	// Exact match
	return cleaned == expected
}

// heartbeatLoop sends periodic status updates while waiting for a connection.
func (s *TFTPService) heartbeatLoop(ctx context.Context, session *TFTPSession) {
	ticker := time.NewTicker(tftpHeartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			elapsed := time.Since(session.started).Round(time.Second)
			s.reportProgress(session.SessionID, 0,
				fmt.Sprintf("listening (%s elapsed)", elapsed))
		case <-ctx.Done():
			return
		case <-session.done:
			return
		}
	}
}

// cleanupSession clears the active session state. Staging files are preserved
// for upload (receive mode) or until TTL expiration. Use CleanupStagingFiles
// to explicitly remove files for a session.
func (s *TFTPService) cleanupSession(session *TFTPSession) {
	s.mu.Lock()
	if s.session != nil && s.session.SessionID == session.SessionID {
		s.session = nil
	}
	s.mu.Unlock()
}

// CleanupStagingFiles removes the staging directory for a session.
func (s *TFTPService) CleanupStagingFiles(sessionID string) {
	sessionDir := filepath.Join(s.stagingDir, sessionID)
	if err := os.RemoveAll(sessionDir); err != nil {
		s.logger.Warn().Err(err).Str("session_id", sessionID).Msg("failed to clean staging dir")
	}
}

// reportProgress reports transfer progress via callback.
func (s *TFTPService) reportProgress(sessionID string, bytesTransferred int64, message string) {
	s.mu.RLock()
	cb := s.onProgress
	s.mu.RUnlock()

	if cb != nil {
		cb(sessionID, bytesTransferred, message)
	}
}

// reportResult reports transfer completion via callback.
func (s *TFTPService) reportResult(sessionID string, success bool, message string, fileSize int64, contentHash string) {
	s.mu.RLock()
	cb := s.onResult
	s.mu.RUnlock()

	if cb != nil {
		cb(sessionID, success, message, fileSize, contentHash)
	}
}

// GetReceivedFilePath returns the path to a received file for upload.
func (s *TFTPService) GetReceivedFilePath(sessionID, filename string) string {
	return filepath.Join(s.stagingDir, sessionID, filepath.Base(filename))
}

// StagingDir returns the staging directory path.
func (s *TFTPService) StagingDir() string {
	return s.stagingDir
}

// stagingCleanupLoop periodically removes staging directories older than stagingTTL.
// It skips directories belonging to the currently active session.
func (s *TFTPService) stagingCleanupLoop() {
	ticker := time.NewTicker(stagingCleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			s.cleanupStaleStagingDirs()
		case <-s.stopClean:
			return
		}
	}
}

// cleanupStaleStagingDirs removes staging session directories past the TTL.
func (s *TFTPService) cleanupStaleStagingDirs() {
	entries, err := os.ReadDir(s.stagingDir)
	if err != nil {
		return
	}

	s.mu.RLock()
	activeSessionID := ""
	if s.session != nil {
		activeSessionID = s.session.SessionID
	}
	s.mu.RUnlock()

	cutoff := time.Now().Add(-s.stagingTTL)

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		// Never remove the active session's staging dir
		if entry.Name() == activeSessionID {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		if info.ModTime().Before(cutoff) {
			dirPath := filepath.Join(s.stagingDir, entry.Name())
			if removeErr := os.RemoveAll(dirPath); removeErr != nil {
				s.logger.Warn().Err(removeErr).Str("dir", dirPath).Msg("failed to remove stale staging dir")
			} else {
				s.logger.Debug().Str("dir", entry.Name()).Msg("removed stale staging directory")
			}
		}
	}
}

// primaryInterfaceAddr returns the primary non-loopback interface address.
func primaryInterfaceAddr() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()

	localAddr := conn.LocalAddr().(*net.UDPAddr)

	return localAddr.IP.String()
}

// limitedWriter wraps a writer with a size limit.
type limitedWriter struct {
	w       io.Writer
	limit   int64
	written int64
}

var errFileSizeLimitExceeded = errors.New("file size limit exceeded")

func (lw *limitedWriter) Write(p []byte) (int, error) {
	if lw.written+int64(len(p)) > lw.limit {
		return 0, errFileSizeLimitExceeded
	}

	n, err := lw.w.Write(p)
	lw.written += int64(n)

	return n, err
}
