package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testRemoteFileTransferSessionID  = "session-1"
	testRemoteFileTransferTransferID = "transfer-1"
	testRemoteFileTransferPath       = "/srv/data"
)

func TestHandleFileTransferFrameExecutesSFTPListForActiveSSHSession(t *testing.T) {
	t.Parallel()

	manager := newRemoteConsoleManagerWithRoute("agent-1", "gateway-1", nil)
	manager.setSSHConfig(testRemoteFileTransferSessionID, remoteaccess.SSHConfig{
		Target: remoteaccess.SSHTarget{Host: "host.example", Port: 22},
		Auth:   remoteaccess.SSHAuth{Username: "alice", PrivateKey: "key"},
	})
	manager.sftpDialer = func(context.Context, remoteaccess.SSHConfig) (remoteaccess.SFTPClient, error) {
		return &fakeRemoteFileTransferSFTPClient{
			entries: []os.FileInfo{
				fakeRemoteFileTransferInfo{name: "app.log", size: 128},
			},
		}, nil
	}

	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{remoteConsoleManager: manager}

	loop.handleConsoleFrame(
		fileTransferRequestFrame(t, remoteaccess.FileTransferOperationList, testRemoteFileTransferPath),
		sender,
	)

	if len(stream.sent) != 2 {
		t.Fatalf("sent frames = %d, want 2", len(stream.sent))
	}

	progress := stream.sent[0].GetConsoleFrame()
	if progress.GetFrameType() != remoteaccess.FrameTypeFileTransferProgress {
		t.Fatalf("progress frame type = %q", progress.GetFrameType())
	}

	outcome := stream.sent[1].GetConsoleFrame()
	if outcome.GetFrameType() != remoteaccess.FrameTypeFileTransferOutcome {
		t.Fatalf("outcome frame type = %q", outcome.GetFrameType())
	}

	var payload struct {
		Status  remoteaccess.FileTransferStatus  `json:"status"`
		Entries []remoteaccess.FileTransferEntry `json:"entries"`
	}
	if err := json.Unmarshal(outcome.GetData(), &payload); err != nil {
		t.Fatalf("decode outcome: %v", err)
	}
	if payload.Status != remoteaccess.FileTransferStatusCompleted {
		t.Fatalf("status = %q", payload.Status)
	}
	if len(payload.Entries) != 1 || payload.Entries[0].Name != "app.log" {
		t.Fatalf("entries = %#v", payload.Entries)
	}
}

func TestHandleFileTransferFrameFailsClosedWithoutActiveSSHSession(t *testing.T) {
	t.Parallel()

	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{remoteConsoleManager: newRemoteConsoleManagerWithRoute("agent-1", "gateway-1", nil)}

	loop.handleConsoleFrame(
		fileTransferRequestFrame(t, remoteaccess.FileTransferOperationList, testRemoteFileTransferPath),
		sender,
	)

	if len(stream.sent) != 1 {
		t.Fatalf("sent frames = %d, want 1", len(stream.sent))
	}

	frame := stream.sent[0].GetConsoleFrame()
	if frame.GetFrameType() != remoteaccess.FrameTypeFileTransferError {
		t.Fatalf("frame type = %q", frame.GetFrameType())
	}

	var payload remoteaccess.FileTransferErrorPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if payload.Message != errRemoteFileTransferSessionNotActive.Error() {
		t.Fatalf("message = %q", payload.Message)
	}
}

func fileTransferRequestFrame(
	t *testing.T,
	operation remoteaccess.FileTransferOperation,
	path string,
) *proto.ConsoleFrame {
	t.Helper()

	direction, err := remoteaccess.DirectionForOperation(operation)
	if err != nil {
		t.Fatal(err)
	}

	payload := remoteaccess.FileTransferRequestPayload{
		Protocol:   remoteaccess.ProtocolSFTP,
		TransferID: testRemoteFileTransferTransferID,
		SessionID:  testRemoteFileTransferSessionID,
		Operation:  operation,
		Direction:  direction,
		Path:       path,
		Policy: remoteaccess.FileTransferPolicy{
			AllowedOperations: []remoteaccess.FileTransferOperation{operation},
			AllowedPathRules:  []string{testRemoteFileTransferPath},
			MaxFiles:          10,
			MaxBytes:          1024,
		},
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}

	return &proto.ConsoleFrame{
		SessionId: testRemoteFileTransferSessionID,
		FrameType: remoteaccess.FrameTypeFileTransferRequest,
		Data:      data,
	}
}

type fakeRemoteFileTransferSFTPClient struct {
	entries []os.FileInfo
}

func (c *fakeRemoteFileTransferSFTPClient) Chmod(string, os.FileMode) error { return nil }
func (c *fakeRemoteFileTransferSFTPClient) Chown(string, int, int) error    { return nil }
func (c *fakeRemoteFileTransferSFTPClient) Close() error                    { return nil }
func (c *fakeRemoteFileTransferSFTPClient) Create(string) (remoteaccess.SFTPFile, error) {
	return fakeRemoteFileTransferFile{Buffer: &bytes.Buffer{}}, nil
}
func (c *fakeRemoteFileTransferSFTPClient) Lstat(string) (os.FileInfo, error) {
	return fakeRemoteFileTransferInfo{name: "data", dir: true}, nil
}
func (c *fakeRemoteFileTransferSFTPClient) Mkdir(string) error { return nil }
func (c *fakeRemoteFileTransferSFTPClient) Open(string) (remoteaccess.SFTPFile, error) {
	return fakeRemoteFileTransferFile{Buffer: bytes.NewBufferString("payload")}, nil
}
func (c *fakeRemoteFileTransferSFTPClient) ReadDir(string) ([]os.FileInfo, error) {
	return c.entries, nil
}
func (c *fakeRemoteFileTransferSFTPClient) RealPath(path string) (string, error) { return path, nil }
func (c *fakeRemoteFileTransferSFTPClient) Remove(string) error                  { return nil }
func (c *fakeRemoteFileTransferSFTPClient) Rename(string, string) error          { return nil }
func (c *fakeRemoteFileTransferSFTPClient) Stat(string) (os.FileInfo, error) {
	return fakeRemoteFileTransferInfo{name: "data", dir: true}, nil
}

type fakeRemoteFileTransferFile struct {
	*bytes.Buffer
}

func (f fakeRemoteFileTransferFile) Close() error { return nil }

type fakeRemoteFileTransferInfo struct {
	name string
	size int64
	dir  bool
}

func (i fakeRemoteFileTransferInfo) Name() string       { return i.name }
func (i fakeRemoteFileTransferInfo) Size() int64        { return i.size }
func (i fakeRemoteFileTransferInfo) Mode() os.FileMode  { return 0o644 }
func (i fakeRemoteFileTransferInfo) ModTime() time.Time { return time.Unix(1_700_000_000, 0) }
func (i fakeRemoteFileTransferInfo) IsDir() bool        { return i.dir }
func (i fakeRemoteFileTransferInfo) Sys() any           { return nil }
