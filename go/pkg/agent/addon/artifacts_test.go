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
	"io"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

type fakeArtifactClient struct {
	chunks <-chan *coreaddon.ArtifactUploadChunk
	err    error
}

func (c fakeArtifactClient) StreamArtifacts(context.Context) (<-chan *coreaddon.ArtifactUploadChunk, error) {
	return c.chunks, c.err
}

type diagnosticArtifactClient struct {
	chunks <-chan *coreaddon.ArtifactUploadChunk
	errs   <-chan error
	err    error
}

func (c diagnosticArtifactClient) StreamArtifacts(context.Context) (<-chan *coreaddon.ArtifactUploadChunk, error) {
	return c.chunks, c.err
}

func (c diagnosticArtifactClient) StreamArtifactsWithDiagnostics(
	context.Context,
) (<-chan *coreaddon.ArtifactUploadChunk, <-chan error, error) {
	return c.chunks, c.errs, c.err
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
	cfg := applyDefaults(Config{
		RuntimeDir: t.TempDir(),
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
			return nil
		},
	})
	r := newRunner(Spec{
		ID:           "feed-addon",
		AssignmentID: "assign-feed-addon",
		DownloadURL:  "https://gateway.example:50053/artifacts/addons/pkg/blob/download",
	}, cfg)

	if err := r.drainArtifactStream(context.Background(), fakeArtifactClient{chunks: chunks}); err != errAddonStreamClosed {
		t.Fatalf("drainArtifactStream error = %v, want %v", err, errAddonStreamClosed)
	}

	if !handled.Load() {
		t.Fatal("artifact handler was not called")
	}
}

func TestRunnerDrainArtifactsReportsEOFAndTransportErrors(t *testing.T) {
	r := newRunner(Spec{ID: "feed-addon"}, applyDefaults(Config{RuntimeDir: t.TempDir()}))

	chunks := make(chan *coreaddon.ArtifactUploadChunk)
	errs := make(chan error, 1)
	errs <- io.EOF
	close(errs)
	close(chunks)

	err := r.drainArtifactStream(context.Background(), diagnosticArtifactClient{chunks: chunks, errs: errs})
	if !errors.Is(err, errAddonStreamClosed) {
		t.Fatalf("drainArtifactStream error = %v, want addon stream closed", err)
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("drainArtifactStream error = %v, want wrapped io.EOF", err)
	}

	transportErr := errors.New("artifact stream reset")
	chunks = make(chan *coreaddon.ArtifactUploadChunk)
	errs = make(chan error, 1)
	errs <- transportErr
	close(errs)
	close(chunks)

	err = r.drainArtifactStream(context.Background(), diagnosticArtifactClient{chunks: chunks, errs: errs})
	if !errors.Is(err, errAddonStreamClosed) {
		t.Fatalf("drainArtifactStream transport error = %v, want addon stream closed", err)
	}
	if !errors.Is(err, transportErr) {
		t.Fatalf("drainArtifactStream transport error = %v, want wrapped transport error", err)
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
	cfg := applyDefaults(Config{
		RuntimeDir: t.TempDir(),
		ArtifactHandler: func(context.Context, ArtifactSubmission) error {
			handled.Store(true)
			return nil
		},
	})
	r := newRunner(Spec{ID: "feed-addon"}, cfg)

	if err := r.drainArtifactStream(context.Background(), fakeArtifactClient{chunks: chunks}); err != errAddonStreamClosed {
		t.Fatalf("drainArtifactStream error = %v, want %v", err, errAddonStreamClosed)
	}

	if handled.Load() {
		t.Fatal("artifact handler called for digest mismatch")
	}
}

func TestRunnerDrainArtifactsReconnectsAfterStreamClose(t *testing.T) {
	body := []byte(`{"advisories":[{"id":"CVE-2026-0002"}]}`)
	sum := sha256.Sum256(body)
	handled := make(chan ArtifactSubmission, 1)
	cfg := applyDefaults(Config{
		RuntimeDir: t.TempDir(),
		ArtifactHandler: func(_ context.Context, submission ArtifactSubmission) error {
			handled <- submission
			return nil
		},
	})
	r := newRunner(Spec{ID: "feed-addon"}, cfg)
	client := &reconnectingArtifactClient{
		opened: make(chan int, 2),
		chunk: &coreaddon.ArtifactUploadChunk{
			Metadata: &coreaddon.ArtifactMetadata{
				ObjectKey: "feeds/reconnected.json",
				Sha256:    hex.EncodeToString(sum[:]),
				SizeBytes: int64(len(body)),
			},
			Data:       body,
			ChunkIndex: 0,
			IsFinal:    true,
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go r.drainArtifacts(ctx, client)

	waitForArtifactStream(t, client.opened, 1)
	waitForArtifactStream(t, client.opened, 2)

	select {
	case submission := <-handled:
		if submission.ObjectKey != "feeds/reconnected.json" {
			t.Fatalf("object key = %q", submission.ObjectKey)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for artifact after reconnect")
	}
}

type reconnectingArtifactClient struct {
	mu      sync.Mutex
	streams int
	opened  chan int
	chunk   *coreaddon.ArtifactUploadChunk
}

func (c *reconnectingArtifactClient) StreamArtifacts(ctx context.Context) (<-chan *coreaddon.ArtifactUploadChunk, error) {
	c.mu.Lock()
	c.streams++
	streamID := c.streams
	c.mu.Unlock()

	chunks := make(chan *coreaddon.ArtifactUploadChunk, 1)
	c.opened <- streamID

	if streamID == 1 {
		close(chunks)
		return chunks, nil
	}

	go func() {
		defer close(chunks)
		select {
		case chunks <- c.chunk:
		case <-ctx.Done():
			return
		}
		<-ctx.Done()
	}()

	return chunks, nil
}

func waitForArtifactStream(t *testing.T, opened <-chan int, want int) {
	t.Helper()

	select {
	case got := <-opened:
		if got != want {
			t.Fatalf("opened artifact stream = %d, want %d", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for artifact stream %d", want)
	}
}
