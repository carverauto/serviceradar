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

package addon

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"os"
	"path/filepath"
	"strings"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

const (
	defaultArtifactMaxBytes = int64(512 * 1024 * 1024)
)

var (
	errArtifactMetadataMissing  = errors.New("artifact metadata missing")
	errArtifactObjectKeyMissing = errors.New("artifact object key missing")
	errArtifactChunkOutOfOrder  = errors.New("artifact chunk out of order")
	errArtifactTooLarge         = errors.New("artifact too large")
	errArtifactSizeMismatch     = errors.New("artifact size mismatch")
	errArtifactDigestMismatch   = errors.New("artifact digest mismatch")
	errArtifactShortWrite       = errors.New("short artifact write")
)

// ArtifactHandler receives a fully staged and locally verified artifact emitted
// by a native add-on. Implementations upload it through the agent-gateway.
type ArtifactHandler func(context.Context, ArtifactSubmission) error

// ArtifactSubmission is the trusted agent-side handoff from the add-on manager
// to the gateway uploader.
type ArtifactSubmission struct {
	AddonID      string
	AssignmentID string
	DownloadURL  string
	ObjectKey    string
	ContentType  string
	SHA256       string
	Size         int64
	FilePath     string
	Attributes   map[string]string
}

type activeArtifact struct {
	addonID      string
	assignmentID string
	downloadURL  string
	metadata     *coreaddon.ArtifactMetadata
	file         *os.File
	path         string
	hasher       hash.Hash
	size         int64
	nextChunk    uint32
	maxBytes     int64
}

func (r *runner) drainArtifacts(ctx context.Context, artifactClient coreaddon.ArtifactClient) {
	diagnostics := streamDiagnostics(artifactClient)

	reconnectStreamLoop(
		ctx,
		r.cfg.RestartBackoffInitial,
		r.cfg.RestartBackoffMax,
		func(ctx context.Context) (<-chan *coreaddon.ArtifactUploadChunk, error) {
			return artifactClient.StreamArtifacts(ctx)
		},
		r.drainArtifactStream,
		func(err error, delay time.Duration) {
			r.cfg.Logger.Warn().
				Err(err).
				Str("addon", r.id).
				Dur("retry_after", delay).
				Msg("addon artifact stream failed to open")
		},
		func(delay time.Duration) {
			diagnostic := readStreamDiagnostic(diagnostics)
			event := r.cfg.Logger.Warn().
				Str("addon", r.id).
				Str("stream", "artifacts").
				Str("stream_end", string(diagnostic.Kind)).
				Dur("retry_after", delay)
			if diagnostic.Err != nil {
				event = event.Err(diagnostic.Err)
			}
			event.Msg("addon artifact stream closed; reconnecting")
		},
	)
}

func (r *runner) drainArtifactStream(ctx context.Context, chunks <-chan *coreaddon.ArtifactUploadChunk) bool {
	madeProgress := false
	var current *activeArtifact
	defer func() {
		if current != nil {
			current.cleanup()
		}
	}()

	for {
		select {
		case <-ctx.Done():
			return madeProgress
		case chunk, ok := <-chunks:
			if !ok {
				return madeProgress
			}
			if chunk == nil {
				continue
			}
			madeProgress = true

			if chunk.GetMetadata() != nil {
				if current != nil {
					r.cfg.Logger.Warn().Str("addon", r.id).Msg("addon artifact stream started a new artifact before finishing the previous one")
					current.cleanup()
				}

				var err error
				current, err = r.newActiveArtifact(chunk.GetMetadata())
				if err != nil {
					r.cfg.Logger.Warn().Err(err).Str("addon", r.id).Msg("addon artifact metadata rejected")
					current = nil
					continue
				}
			}

			if current == nil {
				r.cfg.Logger.Warn().Err(errArtifactMetadataMissing).Str("addon", r.id).Msg("addon artifact chunk rejected")
				continue
			}

			if err := current.write(chunk); err != nil {
				r.cfg.Logger.Warn().Err(err).Str("addon", r.id).Msg("addon artifact chunk rejected")
				current.cleanup()
				current = nil
				continue
			}

			if chunk.GetIsFinal() {
				submission, err := current.finish()
				if err != nil {
					r.cfg.Logger.Warn().Err(err).Str("addon", r.id).Msg("addon artifact rejected")
					current.cleanup()
					current = nil
					continue
				}

				if r.cfg.ArtifactHandler != nil {
					if err := r.cfg.ArtifactHandler(ctx, submission); err != nil {
						r.cfg.Logger.Warn().Err(err).Str("addon", r.id).Str("object_key", submission.ObjectKey).Msg("addon artifact upload failed")
					}
				}

				current.cleanup()
				current = nil
			}
		}
	}
}

func (r *runner) newActiveArtifact(metadata *coreaddon.ArtifactMetadata) (*activeArtifact, error) {
	if metadata == nil {
		return nil, errArtifactMetadataMissing
	}
	if strings.TrimSpace(metadata.GetObjectKey()) == "" {
		return nil, errArtifactObjectKeyMissing
	}

	dir := filepath.Join(r.cfg.RuntimeDir, "artifacts")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}

	file, err := os.CreateTemp(dir, "addon-artifact-*.tmp")
	if err != nil {
		return nil, err
	}

	spec := r.currentSpec()
	assignmentID := strings.TrimSpace(spec.AssignmentID)
	if assignmentID == "" {
		assignmentID = r.id
	}

	maxBytes := r.cfg.ArtifactMaxBytes
	if maxBytes <= 0 {
		maxBytes = defaultArtifactMaxBytes
	}

	return &activeArtifact{
		addonID:      r.id,
		assignmentID: assignmentID,
		downloadURL:  spec.DownloadURL,
		metadata:     metadata,
		file:         file,
		path:         file.Name(),
		hasher:       sha256.New(),
		maxBytes:     maxBytes,
	}, nil
}

func (a *activeArtifact) write(chunk *coreaddon.ArtifactUploadChunk) error {
	if chunk.GetChunkIndex() != a.nextChunk {
		return fmt.Errorf("%w: got %d want %d", errArtifactChunkOutOfOrder, chunk.GetChunkIndex(), a.nextChunk)
	}

	data := chunk.GetData()
	if a.maxBytes > 0 && a.size+int64(len(data)) > a.maxBytes {
		return fmt.Errorf("%w: max %d bytes", errArtifactTooLarge, a.maxBytes)
	}

	if len(data) > 0 {
		n, err := a.file.Write(data)
		if err != nil {
			return err
		}
		if n != len(data) {
			return fmt.Errorf("%w: %d of %d", errArtifactShortWrite, n, len(data))
		}
		if _, err := a.hasher.Write(data); err != nil {
			return err
		}
		a.size += int64(len(data))
	}

	a.nextChunk++
	return nil
}

func (a *activeArtifact) finish() (ArtifactSubmission, error) {
	if err := a.file.Close(); err != nil {
		return ArtifactSubmission{}, err
	}
	a.file = nil

	if want := a.metadata.GetSizeBytes(); want > 0 && want != a.size {
		return ArtifactSubmission{}, fmt.Errorf("%w: got %d want %d", errArtifactSizeMismatch, a.size, want)
	}

	actualSHA := hex.EncodeToString(a.hasher.Sum(nil))
	if want := strings.ToLower(strings.TrimSpace(a.metadata.GetSha256())); want != "" && want != actualSHA {
		return ArtifactSubmission{}, fmt.Errorf("%w: got %s want %s", errArtifactDigestMismatch, actualSHA, want)
	}

	return ArtifactSubmission{
		AddonID:      a.addonID,
		AssignmentID: a.assignmentID,
		DownloadURL:  a.downloadURL,
		ObjectKey:    a.metadata.GetObjectKey(),
		ContentType:  a.metadata.GetContentType(),
		SHA256:       actualSHA,
		Size:         a.size,
		FilePath:     a.path,
		Attributes:   cloneStringMap(a.metadata.GetAttributes()),
	}, nil
}

func (a *activeArtifact) cleanup() {
	if a == nil {
		return
	}
	if a.file != nil {
		_ = a.file.Close()
	}
	if a.path != "" {
		_ = os.Remove(a.path)
	}
}

func cloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}
