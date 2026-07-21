package agent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

type fakePluginArtifactUploader struct {
	request PluginArtifactUploadRequest
}

func (u *fakePluginArtifactUploader) UploadPluginArtifact(
	_ context.Context,
	request PluginArtifactUploadRequest,
) (PluginArtifactUploadResponse, error) {
	u.request = request

	return PluginArtifactUploadResponse{
		ObjectKey:   "agent-artifacts/agent-1/assignment-1/feeds/nvd.json",
		ContentType: request.ContentType,
		SHA256:      request.SHA256,
		SizeBytes:   request.Size,
	}, nil
}

func TestPluginArtifactStreamCommitsThroughUploader(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	uploader := &fakePluginArtifactUploader{}
	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		LocalStoreDir:    dir,
		Logger:           logger.NewTestLogger(),
		ArtifactUploader: uploader,
	})
	defer manager.Stop()

	exec := newPluginExecution(manager, &pluginAssignment{
		AssignmentID: "assignment-1",
		PluginID:     "plugin-1",
		Name:         "feed plugin",
		Capabilities: map[string]bool{pluginCapabilityArtifactStaging: true},
		DownloadURL:  "https://gateway.example:50053/artifacts/plugins/package-1/blob/download",
	})

	body := []byte(`{"advisories":[]}`)
	sum := sha256.Sum256(body)
	expectedSHA := hex.EncodeToString(sum[:])

	stream, err := exec.newArtifactStream(pluginArtifactOpenRequest{
		ObjectKey:   "feeds/nvd.json",
		ContentType: "application/json",
		SHA256:      expectedSHA,
		SizeBytes:   int64(len(body)),
	})
	if err != nil {
		t.Fatalf("newArtifactStream: %v", err)
	}

	handle := exec.storeArtifactStream(stream)
	if handle == 0 {
		t.Fatal("expected artifact handle")
	}

	if err := stream.write(body, pluginArtifactChunkMetadata{}); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	if err := stream.close(); err != nil {
		t.Fatalf("close artifact: %v", err)
	}
	if err := stream.verify(pluginArtifactCommitRequest{}); err != nil {
		t.Fatalf("verify artifact: %v", err)
	}

	deleted := exec.deleteArtifactStream(handle)
	if deleted == nil {
		t.Fatal("expected artifact stream")
		return
	}

	response, err := manager.artifactUploaderResolver().UploadPluginArtifact(context.Background(), PluginArtifactUploadRequest{
		AssignmentID: exec.assignment.AssignmentID,
		PluginID:     exec.assignment.PluginID,
		PluginName:   exec.assignment.Name,
		DownloadURL:  exec.assignment.DownloadURL,
		ObjectKey:    deleted.objectKey,
		ContentType:  deleted.contentType,
		SHA256:       deleted.actualSHA256(),
		Size:         deleted.size,
		FilePath:     deleted.path,
	})
	if err != nil {
		t.Fatalf("upload artifact: %v", err)
	}
	deleted.cleanup()

	if response.ObjectKey != "agent-artifacts/agent-1/assignment-1/feeds/nvd.json" {
		t.Fatalf("unexpected object key %q", response.ObjectKey)
	}
	if uploader.request.ObjectKey != "feeds/nvd.json" {
		t.Fatalf("uploader object key = %q", uploader.request.ObjectKey)
	}
	if uploader.request.SHA256 != expectedSHA {
		t.Fatalf("uploader sha = %q, want %q", uploader.request.SHA256, expectedSHA)
	}
	if _, err := os.Stat(deleted.path); !os.IsNotExist(err) {
		t.Fatalf("expected temp file cleanup for %s, got err=%v", deleted.path, err)
	}

	if filepath.Dir(deleted.path) != filepath.Join(dir, "plugin-artifacts") {
		t.Fatalf("artifact path %q was not under plugin artifact dir", deleted.path)
	}
}

func TestPluginArtifactUploadURLUsesGatewayArtifactEndpoint(t *testing.T) {
	t.Parallel()

	uploadURL, err := pluginArtifactUploadURL("https://gateway.example:50053/artifacts/plugins/pkg/blob/download?ignored=1")
	if err != nil {
		t.Fatalf("pluginArtifactUploadURL: %v", err)
	}

	if uploadURL != "https://gateway.example:50053/artifacts/agent-artifacts/upload" {
		t.Fatalf("upload URL = %q", uploadURL)
	}
}

func TestPluginArtifactRejectsUnsafeObjectKey(t *testing.T) {
	t.Parallel()

	for _, key := range []string{"../nvd.json", "/feeds/nvd.json", "feeds//nvd.json", "feeds/nvd json"} {
		if validPluginArtifactObjectKey(key) {
			t.Fatalf("expected unsafe key %q to be rejected", key)
		}
	}
}
