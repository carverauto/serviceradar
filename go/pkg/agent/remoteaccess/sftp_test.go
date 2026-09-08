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

package remoteaccess

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"testing"
	"testing/iotest"
	"time"
)

func TestSFTPAdapterUploadRejectsMissingContentBeforeCreate(t *testing.T) {
	t.Parallel()

	for _, existing := range []bool{false, true} {
		for _, name := range []string{"missing", "empty", "stream EOF", "unreadable"} {
			t.Run(fmt.Sprintf("%s/existing=%t", name, existing), func(t *testing.T) {
				client := newFakeSFTPClient()
				path := "/srv/data/upload.txt"
				if existing {
					client.files[path] = []byte("original content")
				}
				var input io.Reader
				wantErr := ErrSFTPInputRequired
				switch name {
				case "empty":
					input = bytes.NewReader(nil)
					wantErr = ErrSFTPInputEmpty
				case "stream EOF":
					reader, writer := io.Pipe()
					defer func() {
						if err := reader.Close(); err != nil {
							t.Error(err)
						}
					}()
					if err := writer.Close(); err != nil {
						t.Fatal(err)
					}
					input = reader
					wantErr = ErrSFTPInputEmpty
				case "unreadable":
					input = iotest.ErrReader(os.ErrPermission)
					wantErr = os.ErrPermission
				}

				adapter := testSFTPAdapter(client, FileTransferOperationUpload)
				result, err := adapter.Execute(t.Context(), SSHConfig{},
					testSFTPRequest(FileTransferOperationUpload, path), input, nil)
				if !errors.Is(err, wantErr) {
					t.Fatalf("Execute error = %v, want %v", err, wantErr)
				}
				if result.Outcome.Status != FileTransferStatusFailed || result.Outcome.FailureReason == "" {
					t.Fatalf("expected visible failure, got %#v", result.Outcome)
				}
				if slices.Contains(client.ops, "create:"+path) || slices.Contains(client.ops, "remove:"+path) {
					t.Fatalf("invalid upload mutated destination: %v", client.ops)
				}
				data, exists := client.files[path]
				if exists != existing || (existing && string(data) != "original content") {
					t.Fatalf("destination changed: exists=%t, data=%q", exists, data)
				}
			})
		}
	}
}

func TestSFTPAdapterUploadPreservesBufferedContent(t *testing.T) {
	t.Parallel()

	for _, content := range []string{"x", "complete upload content"} {
		t.Run(content, func(t *testing.T) {
			client := newFakeSFTPClient()
			adapter := testSFTPAdapter(client, FileTransferOperationUpload)
			adapter.MaxChunkBytes = 3
			result, err := adapter.Execute(t.Context(), SSHConfig{},
				testSFTPRequest(FileTransferOperationUpload, "/srv/data/upload.txt"),
				iotest.OneByteReader(bytes.NewBufferString(content)), nil)
			if err != nil {
				t.Fatal(err)
			}
			if string(client.files["/srv/data/upload.txt"]) != content {
				t.Fatalf("uploaded content = %q, want %q", client.files["/srv/data/upload.txt"], content)
			}
			if result.Outcome.Status != FileTransferStatusCompleted || result.Outcome.BytesTransferred != int64(len(content)) {
				t.Fatalf("unexpected outcome: %#v", result.Outcome)
			}
		})
	}
}

func TestSFTPAdapterDownloadUsesSharedSSHDialerAndPolicy(t *testing.T) {
	t.Parallel()

	client := newFakeSFTPClient()
	client.files["/srv/data/report.txt"] = []byte("report")

	var output bytes.Buffer
	adapter := testSFTPAdapter(client, FileTransferOperationDownload)

	result, err := adapter.Execute(
		t.Context(),
		SSHConfig{Target: SSHTarget{Host: "host.example", Port: 22}},
		testSFTPRequest(FileTransferOperationDownload, "/srv/data/report.txt"),
		nil,
		&output,
	)
	if err != nil {
		t.Fatalf("Execute returned error: %v", err)
	}

	if output.String() != "report" {
		t.Fatalf("download output = %q, want report", output.String())
	}
	if result.Outcome.Status != FileTransferStatusCompleted || result.Outcome.BytesTransferred != 6 {
		t.Fatalf("outcome = %#v", result.Outcome)
	}
	if !client.closed {
		t.Fatal("expected SFTP client to close")
	}
	if !slices.Contains(client.ops, "open:/srv/data/report.txt") {
		t.Fatalf("ops = %#v, want open", client.ops)
	}
}

func TestSFTPAdapterUploadRemovesPartialFileOnQuotaFailure(t *testing.T) {
	t.Parallel()

	client := newFakeSFTPClient()
	adapter := testSFTPAdapter(client, FileTransferOperationUpload)
	adapter.Policy.MaxBytes = 4

	_, err := adapter.Execute(
		t.Context(),
		SSHConfig{},
		testSFTPRequest(FileTransferOperationUpload, "/srv/data/upload.txt"),
		bytes.NewBufferString("too-large"),
		nil,
	)
	if !errors.Is(err, ErrFileTransferQuotaExceeded) {
		t.Fatalf("Execute error = %v, want %v", err, ErrFileTransferQuotaExceeded)
	}
	if _, ok := client.files["/srv/data/upload.txt"]; ok {
		t.Fatal("partial upload was retained after quota failure")
	}
	if !slices.Contains(client.ops, "remove:/srv/data/upload.txt") {
		t.Fatalf("ops = %#v, want partial cleanup remove", client.ops)
	}
}

func TestSFTPAdapterListAndMutations(t *testing.T) {
	t.Parallel()

	client := newFakeSFTPClient()
	client.dirs["/srv/data"] = []os.FileInfo{
		fakeFileInfo{name: "a.txt", size: 12},
		fakeFileInfo{name: "subdir", mode: os.ModeDir},
	}
	client.files["/srv/data/old.txt"] = []byte("old")
	adapter := testSFTPAdapter(client, FileTransferOperationList, FileTransferOperationMkdir,
		FileTransferOperationRename, FileTransferOperationRemove, FileTransferOperationChmod, FileTransferOperationChown)
	adapter.ChmodMode = 0o640
	adapter.ChmodModeSet = true
	adapter.ChownUID = 1000
	adapter.ChownGID = 1001
	adapter.ChownSet = true

	result, err := adapter.Execute(t.Context(), SSHConfig{}, testSFTPRequest(FileTransferOperationList, "/srv/data"), nil, nil)
	if err != nil {
		t.Fatalf("list Execute returned error: %v", err)
	}
	if len(result.Entries) != 2 || result.Outcome.FilesTransferred != 2 {
		t.Fatalf("list result = %#v", result)
	}

	mutations := []FileTransferRequestPayload{
		testSFTPRequest(FileTransferOperationMkdir, "/srv/data/new"),
		renameSFTPRequest("/srv/data/old.txt", "/srv/data/new.txt"),
		testSFTPRequest(FileTransferOperationChmod, "/srv/data/new.txt"),
		testSFTPRequest(FileTransferOperationChown, "/srv/data/new.txt"),
		testSFTPRequest(FileTransferOperationRemove, "/srv/data/new.txt"),
	}

	for _, request := range mutations {
		if _, err := adapter.Execute(t.Context(), SSHConfig{}, request, nil, nil); err != nil {
			t.Fatalf("%s Execute returned error: %v", request.Operation, err)
		}
	}

	for _, want := range []string{
		"mkdir:/srv/data/new",
		"rename:/srv/data/old.txt:/srv/data/new.txt",
		"chmod:/srv/data/new.txt:0640",
		"chown:/srv/data/new.txt:1000:1001",
		"remove:/srv/data/new.txt",
	} {
		if !slices.Contains(client.ops, want) {
			t.Fatalf("ops = %#v, want %q", client.ops, want)
		}
	}
}

func TestSFTPAdapterDeniesBeforeOpeningFile(t *testing.T) {
	t.Parallel()

	client := newFakeSFTPClient()
	client.files["/etc/passwd"] = []byte("root")
	adapter := testSFTPAdapter(client, FileTransferOperationDownload)

	_, err := adapter.Execute(
		t.Context(),
		SSHConfig{},
		testSFTPRequest(FileTransferOperationDownload, "/etc/passwd"),
		nil,
		io.Discard,
	)
	if !errors.Is(err, ErrFileTransferPolicyDenied) {
		t.Fatalf("Execute error = %v, want %v", err, ErrFileTransferPolicyDenied)
	}
	if slices.Contains(client.ops, "open:/etc/passwd") {
		t.Fatalf("opened denied path, ops = %#v", client.ops)
	}
}

func TestSFTPAdapterDeniesSymlinkWhenRealPathFails(t *testing.T) {
	t.Parallel()

	client := newFakeSFTPClient()
	client.symlinks["/srv/data/link"] = true
	client.realPathErr = os.ErrPermission
	adapter := testSFTPAdapter(client, FileTransferOperationDownload)
	adapter.Policy.SymlinkMode = FileTransferSymlinkFollowInsideRoot

	_, err := adapter.Execute(
		t.Context(),
		SSHConfig{},
		testSFTPRequest(FileTransferOperationDownload, "/srv/data/link"),
		nil,
		io.Discard,
	)
	if !errors.Is(err, ErrFileTransferPolicyDenied) {
		t.Fatalf("Execute error = %v, want %v", err, ErrFileTransferPolicyDenied)
	}
	if slices.Contains(client.ops, "open:/srv/data/link") {
		t.Fatalf("opened unresolved symlink, ops = %#v", client.ops)
	}
}

func testSFTPAdapter(client *fakeSFTPClient, operations ...FileTransferOperation) SFTPAdapter {
	return SFTPAdapter{
		Dial: func(context.Context, SSHConfig) (SFTPClient, error) {
			client.ops = append(client.ops, "dial")
			return client, nil
		},
		Policy: FileTransferPolicy{
			AllowedOperations: operations,
			AllowedPathRules:  []string{"/srv/data"},
			MaxBytes:          1_024,
			MaxFiles:          10,
		},
	}
}

func testSFTPRequest(operation FileTransferOperation, path string) FileTransferRequestPayload {
	direction, _ := DirectionForOperation(operation)

	return FileTransferRequestPayload{
		Protocol:   ProtocolSFTP,
		TransferID: "transfer-1",
		SessionID:  "session-1",
		Operation:  operation,
		Direction:  direction,
		Path:       path,
	}
}

func renameSFTPRequest(path string, destination string) FileTransferRequestPayload {
	request := testSFTPRequest(FileTransferOperationRename, path)
	request.DestinationPath = destination

	return request
}

type fakeSFTPClient struct {
	files       map[string][]byte
	dirs        map[string][]os.FileInfo
	symlinks    map[string]bool
	realPathErr error
	ops         []string
	closed      bool
}

func newFakeSFTPClient() *fakeSFTPClient {
	return &fakeSFTPClient{
		files:    make(map[string][]byte),
		dirs:     make(map[string][]os.FileInfo),
		symlinks: make(map[string]bool),
	}
}

func (c *fakeSFTPClient) Chmod(path string, mode os.FileMode) error {
	c.ops = append(c.ops, fmt.Sprintf("chmod:%s:%04o", path, mode.Perm()))
	return nil
}

func (c *fakeSFTPClient) Chown(path string, uid int, gid int) error {
	c.ops = append(c.ops, fmt.Sprintf("chown:%s:%d:%d", path, uid, gid))
	return nil
}

func (c *fakeSFTPClient) Close() error {
	c.closed = true
	return nil
}

func (c *fakeSFTPClient) Create(path string) (SFTPFile, error) {
	c.ops = append(c.ops, "create:"+path)
	return &fakeSFTPFile{onClose: func(data []byte) { c.files[path] = data }}, nil
}

func (c *fakeSFTPClient) Lstat(path string) (os.FileInfo, error) {
	if c.symlinks[path] {
		return fakeFileInfo{name: pathBase(path), mode: os.ModeSymlink}, nil
	}

	return c.Stat(path)
}

func (c *fakeSFTPClient) Mkdir(path string) error {
	c.ops = append(c.ops, "mkdir:"+path)
	c.dirs[path] = nil
	return nil
}

func (c *fakeSFTPClient) Open(path string) (SFTPFile, error) {
	c.ops = append(c.ops, "open:"+path)
	data, ok := c.files[path]
	if !ok {
		return nil, os.ErrNotExist
	}

	return &fakeSFTPFile{reader: bytes.NewReader(data)}, nil
}

func (c *fakeSFTPClient) ReadDir(path string) ([]os.FileInfo, error) {
	c.ops = append(c.ops, "readdir:"+path)
	entries, ok := c.dirs[path]
	if !ok {
		return nil, os.ErrNotExist
	}

	return entries, nil
}

func (c *fakeSFTPClient) RealPath(path string) (string, error) {
	c.ops = append(c.ops, "realpath:"+path)
	if c.realPathErr != nil {
		return "", c.realPathErr
	}

	return path, nil
}

func (c *fakeSFTPClient) Remove(path string) error {
	c.ops = append(c.ops, "remove:"+path)
	delete(c.files, path)
	delete(c.dirs, path)
	return nil
}

func (c *fakeSFTPClient) Rename(oldname string, newname string) error {
	c.ops = append(c.ops, "rename:"+oldname+":"+newname)
	c.files[newname] = c.files[oldname]
	delete(c.files, oldname)
	return nil
}

func (c *fakeSFTPClient) Stat(path string) (os.FileInfo, error) {
	if data, ok := c.files[path]; ok {
		return fakeFileInfo{name: pathBase(path), size: int64(len(data))}, nil
	}
	if _, ok := c.dirs[path]; ok {
		return fakeFileInfo{name: pathBase(path), mode: os.ModeDir}, nil
	}

	return nil, os.ErrNotExist
}

type fakeSFTPFile struct {
	reader  *bytes.Reader
	buffer  bytes.Buffer
	onClose func([]byte)
}

func (f *fakeSFTPFile) Read(p []byte) (int, error) {
	if f.reader == nil {
		return 0, io.EOF
	}

	return f.reader.Read(p)
}

func (f *fakeSFTPFile) Write(p []byte) (int, error) {
	return f.buffer.Write(p)
}

func (f *fakeSFTPFile) Close() error {
	if f.onClose != nil {
		f.onClose(append([]byte(nil), f.buffer.Bytes()...))
	}

	return nil
}

type fakeFileInfo struct {
	name string
	size int64
	mode os.FileMode
}

func (f fakeFileInfo) Name() string {
	return f.name
}

func (f fakeFileInfo) Size() int64 {
	return f.size
}

func (f fakeFileInfo) Mode() os.FileMode {
	return f.mode
}

func (f fakeFileInfo) ModTime() time.Time {
	return time.Unix(0, 0).UTC()
}

func (f fakeFileInfo) IsDir() bool {
	return f.mode&os.ModeDir != 0
}

func (f fakeFileInfo) Sys() any {
	return nil
}

func pathBase(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			return path[i+1:]
		}
	}

	return path
}
