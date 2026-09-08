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
	"os"
	"sync/atomic"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/rs/zerolog"
)

type fakeArtifactClient struct {
	chunks <-chan *coreaddon.ArtifactUploadChunk
	err    error
}

func (c fakeArtifactClient) StreamArtifacts(context.Context) (<-chan *coreaddon.ArtifactUploadChunk, error) {
	return c.chunks, c.err
}

type reconnectingArtifactClient struct {
	calls  atomic.Int32
	chunks []*coreaddon.ArtifactUploadChunk
}

func (c *reconnectingArtifactClient) StreamArtifacts(context.Context) (<-chan *coreaddon.ArtifactUploadChunk, error) {
	call := c.calls.Add(1)
	chunks := make(chan *coreaddon.ArtifactUploadChunk, len(c.chunks))
	if call == 1 {
		close(chunks)
		return chunks, nil
	}
	for _, chunk := range c.chunks {
		chunks <- chunk
	}
	close(chunks)
	return chunks, nil
}

func TestRunnerDrainsAddonArtifactsThroughHandler(t *testing.T) {
	body := []byte(`{"advisories":[{"id":"CVE-2026-0001"}]}`)
	sum := sha256.Sum256(body)
	chunks := make(chan *coreaddon.ArtifactUploadChunk, 1)
	chunks <- &coreaddon.ArtifactUploadChunk{
		Metadata: &coreaddon.ArtifactMetadata{
			ObjectKey:   "feeds/example.json",
			ContentType: "application/json",
			Sha256:      hex.EncodeToString(sum[:]),
			SizeBytes:   int64(len(body)),
			Attributes: map[string]string{
				"contract": "serviceradar.advisory_feed.contract.v1",
			},
		},
		Data:       body,
		ChunkIndex: 0,
		IsFinal:    true,
	}
	close(chunks)

	var handled atomic.Bool
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := applyDefaults(Config{
		RuntimeDir:            t.TempDir(),
		RestartBackoffInitial: time.Millisecond,
		RestartBackoffMax:     time.Millisecond,
		ArtifactHandler: func(_ context.Context, submission ArtifactSubmission) error {
			got, err := os.ReadFile(submission.FilePath)
			if err != nil {
				t.Fatalf("read staged artifact: %v", err)
			}
			if string(got) != string(body) {
				t.Fatalf("staged body = %q, want %q", got, body)
			}
			if submission.AddonID != "feed-addon" {
				t.Fatalf("addon id = %q", submission.AddonID)
			}
			if submission.AssignmentID != "assign-feed-addon" {
				t.Fatalf("assignment id = %q", submission.AssignmentID)
			}
			if submission.DownloadURL != "https://gateway.example:50053/artifacts/addons/pkg/blob/download" {
				t.Fatalf("download url = %q", submission.DownloadURL)
			}
			if submission.ObjectKey != "feeds/example.json" {
				t.Fatalf("object key = %q", submission.ObjectKey)
			}
			if submission.ContentType != "application/json" {
				t.Fatalf("content type = %q", submission.ContentType)
			}
			if submission.SHA256 != hex.EncodeToString(sum[:]) {
				t.Fatalf("sha256 = %q", submission.SHA256)
			}
			if submission.Size != int64(len(body)) {
				t.Fatalf("size = %d", submission.Size)
			}
			if submission.Attributes["contract"] != "serviceradar.advisory_feed.contract.v1" {
				t.Fatalf("attributes = %#v", submission.Attributes)
			}
			handled.Store(true)
			cancel()
			return nil
		},
	})
	r := newRunner(Spec{
		ID:           "feed-addon",
		AssignmentID: "assign-feed-addon",
		DownloadURL:  "https://gateway.example:50053/artifacts/addons/pkg/blob/download",
	}, cfg)

	r.drainArtifacts(ctx, fakeArtifactClient{chunks: chunks})

	if !handled.Load() {
		t.Fatal("artifact handler was not called")
	}
}

func TestRunnerDrainArtifactsReconnectsAfterStreamClose(t *testing.T) {
	body := []byte(`{"advisories":[{"id":"CVE-2026-0002"}]}`)
	sum := sha256.Sum256(body)
	client := &reconnectingArtifactClient{
		chunks: []*coreaddon.ArtifactUploadChunk{{
			Metadata: &coreaddon.ArtifactMetadata{
				ObjectKey: "feeds/reconnect.json",
				Sha256:    hex.EncodeToString(sum[:]),
				SizeBytes: int64(len(body)),
			},
			Data:       body,
			ChunkIndex: 0,
			IsFinal:    true,
		}},
	}
	handled := make(chan struct{}, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := applyDefaults(Config{
		RuntimeDir:            t.TempDir(),
		RestartBackoffInitial: time.Millisecond,
		RestartBackoffMax:     time.Millisecond,
		Logger:                zerolog.Nop(),
		ArtifactHandler: func(context.Context, ArtifactSubmission) error {
			handled <- struct{}{}
			return nil
		},
	})
	r := newRunner(Spec{ID: "feed-addon"}, cfg)

	go r.drainArtifacts(ctx, client)

	select {
	case <-handled:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for artifact after reconnect")
	}

	if got := client.calls.Load(); got < 2 {
		t.Fatalf("StreamArtifacts calls = %d, want at least 2", got)
	}
}

func TestRunnerRejectsAddonArtifactDigestMismatch(t *testing.T) {
	chunks := make(chan *coreaddon.ArtifactUploadChunk, 1)
	chunks <- &coreaddon.ArtifactUploadChunk{
		Metadata: &coreaddon.ArtifactMetadata{
			ObjectKey: "feeds/example.json",
			Sha256:    "0000000000000000000000000000000000000000000000000000000000000000",
		},
		Data:       []byte("body"),
		ChunkIndex: 0,
		IsFinal:    true,
	}
	close(chunks)

	var handled atomic.Bool
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	cfg := applyDefaults(Config{
		RuntimeDir:            t.TempDir(),
		RestartBackoffInitial: time.Millisecond,
		RestartBackoffMax:     time.Millisecond,
		ArtifactHandler: func(context.Context, ArtifactSubmission) error {
			handled.Store(true)
			return nil
		},
	})
	r := newRunner(Spec{ID: "feed-addon"}, cfg)

	r.drainArtifacts(ctx, fakeArtifactClient{chunks: chunks})

	if handled.Load() {
		t.Fatal("artifact handler called for digest mismatch")
	}
}
