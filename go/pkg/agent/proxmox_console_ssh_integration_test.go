//go:build integration
// +build integration

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
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/go/pkg/remoteaccess/sshca"
	"github.com/carverauto/serviceradar/proto"
	"golang.org/x/crypto/ssh"
)

func TestProxmoxConsoleManagerAuthenticatesToTrustedUserCATarget(t *testing.T) {
	t.Parallel()

	target := integrationSSHTargetFromEnv(t)
	if target.Host == "" {
		target = startLocalTrustedUserCATarget(t)
	}

	userPrivateKey, userPublicKey := generateIntegrationUserKey(t)
	ca, err := sshca.New(target.CAPrivateKey, nil, sshca.WithMaxTTL(time.Hour))
	if err != nil {
		t.Fatalf("initialize ServiceRadar SSH CA: %v", err)
	}

	signed, err := ca.SignUserCertificate(sshca.UserCertificateRequest{
		PublicKey:  userPublicKey,
		KeyID:      fmt.Sprintf("sr:remote-access:%s:test-actor:%s:ssh:%s", target.SessionID, target.AgentID, target.Host),
		Principals: []string{target.Principal},
		TTL:        5 * time.Minute,
		Serial:     43,
	})
	if err != nil {
		t.Fatalf("sign user certificate: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	manager := newProxmoxConsoleManagerWithAgentID(target.AgentID, createTestLogger())
	sender := newFakeProxmoxConsoleSender()
	openPayload := remoteaccess.SSHOpenPayload{
		Protocol:       remoteaccess.ProtocolSSH,
		SessionID:      target.SessionID,
		AgentID:        target.AgentID,
		Target:         remoteaccess.SSHTarget{Host: target.Host, Port: target.Port},
		CredentialMode: remoteaccess.SSHCredentialModeSSHCertificate,
		SSH: remoteaccess.SSHAuth{
			Username:    target.Username,
			PrivateKey:  string(userPrivateKey),
			Certificate: string(signed.AuthorizedKey),
		},
		SSHHostKeyPolicy: "skip_verify",
		TerminalType:     "xterm-256color",
		TimeoutMS:        10_000,
	}
	openData, err := json.Marshal(openPayload)
	if err != nil {
		t.Fatalf("marshal open payload: %v", err)
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: consoleFrameTypeOpen,
		Cols:      100,
		Rows:      30,
		Data:      openData,
	}, sender)

	ready := nextIntegrationFrame(t, sender, consoleFrameTypeReady, 15*time.Second)
	if ready.GetSessionId() != target.SessionID {
		t.Fatalf("ready SessionId = %q, want %q", ready.GetSessionId(), target.SessionID)
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: consoleFrameTypeData,
		Data:      []byte("printf serviceradar-agent-routed-sshca\\n; exit\n"),
	}, sender)

	var output bytes.Buffer
	deadline := time.After(15 * time.Second)
	for !strings.Contains(output.String(), "serviceradar-agent-routed-sshca") {
		select {
		case frame := <-sender.ch:
			switch frame.GetFrameType() {
			case consoleFrameTypeData:
				_, _ = output.Write(frame.GetData())
			case consoleFrameTypeError:
				t.Fatalf("received error frame: %s\noutput:\n%s", frame.GetReason(), output.String())
			}
		case <-deadline:
			t.Fatalf("timed out waiting for SSH output marker\noutput:\n%s", output.String())
		}
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: consoleFrameTypeClose,
		Reason:    "integration complete",
	}, sender)
}

func TestProxmoxConsoleManagerTransfersFilesAgainstTrustedUserCATarget(t *testing.T) {
	t.Parallel()

	target := integrationSSHTargetFromEnv(t)
	if target.Host == "" {
		target = startLocalTrustedUserCATarget(t)
	}
	if target.RemoteDir == "" {
		t.Skip("SERVICERADAR_REMOTE_ACCESS_SSH_TEST_DIR is required for external file-transfer integration targets")
	}

	userPrivateKey, userPublicKey := generateIntegrationUserKey(t)
	ca, err := sshca.New(target.CAPrivateKey, nil, sshca.WithMaxTTL(time.Hour))
	if err != nil {
		t.Fatalf("initialize ServiceRadar SSH CA: %v", err)
	}

	signed, err := ca.SignUserCertificate(sshca.UserCertificateRequest{
		PublicKey:  userPublicKey,
		KeyID:      fmt.Sprintf("sr:remote-access:%s:test-actor:%s:ssh:%s", target.SessionID, target.AgentID, target.Host),
		Principals: []string{target.Principal},
		TTL:        5 * time.Minute,
		Serial:     44,
	})
	if err != nil {
		t.Fatalf("sign user certificate: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	manager := newProxmoxConsoleManagerWithAgentID(target.AgentID, createTestLogger())
	sender := newFakeProxmoxConsoleSender()
	openTrustedUserCASession(t, ctx, manager, sender, target, userPrivateKey, signed.AuthorizedKey)

	const uploadPayload = "serviceradar-sftp-proof\n"
	uploadPath := target.RemoteDir + "/serviceradar-sftp-proof.txt"
	manager.HandleFileTransferFrame(
		ctx,
		integrationFileTransferRequestFrame(t, target, remoteaccess.FileTransferOperationUpload, uploadPath),
		sender,
	)
	manager.HandleFileTransferFrame(ctx, integrationFileTransferDataFrame(t, target, 1, 0, []byte(uploadPayload), false), sender)
	manager.HandleFileTransferFrame(ctx, integrationFileTransferDataFrame(t, target, 2, int64(len(uploadPayload)), nil, true), sender)
	assertIntegrationFileTransferOutcome(t, sender, remoteaccess.FileTransferStatusCompleted, int64(len(uploadPayload)), 15*time.Second)

	manager.HandleFileTransferFrame(
		ctx,
		integrationFileTransferRequestFrame(t, target, remoteaccess.FileTransferOperationDownload, uploadPath),
		sender,
	)
	assertIntegrationDownloadPayload(t, sender, uploadPayload, 15*time.Second)

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: consoleFrameTypeClose,
		Reason:    "integration complete",
	}, sender)
}

func openTrustedUserCASession(
	t *testing.T,
	ctx context.Context,
	manager *proxmoxConsoleManager,
	sender *fakeProxmoxConsoleSender,
	target integrationSSHTarget,
	userPrivateKey []byte,
	userCertificate []byte,
) {
	t.Helper()

	openPayload := remoteaccess.SSHOpenPayload{
		Protocol:       remoteaccess.ProtocolSSH,
		SessionID:      target.SessionID,
		AgentID:        target.AgentID,
		Target:         remoteaccess.SSHTarget{Host: target.Host, Port: target.Port},
		CredentialMode: remoteaccess.SSHCredentialModeSSHCertificate,
		SSH: remoteaccess.SSHAuth{
			Username:    target.Username,
			PrivateKey:  string(userPrivateKey),
			Certificate: string(userCertificate),
		},
		SSHHostKeyPolicy: "skip_verify",
		TerminalType:     "xterm-256color",
		TimeoutMS:        10_000,
	}
	openData, err := json.Marshal(openPayload)
	if err != nil {
		t.Fatalf("marshal open payload: %v", err)
	}

	manager.HandleFrame(ctx, &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: consoleFrameTypeOpen,
		Cols:      100,
		Rows:      30,
		Data:      openData,
	}, sender)

	ready := nextIntegrationFrame(t, sender, consoleFrameTypeReady, 15*time.Second)
	if ready.GetSessionId() != target.SessionID {
		t.Fatalf("ready SessionId = %q, want %q", ready.GetSessionId(), target.SessionID)
	}
}

func integrationFileTransferRequestFrame(
	t *testing.T,
	target integrationSSHTarget,
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
		TransferID: fmt.Sprintf("integration-%s", operation),
		SessionID:  target.SessionID,
		Operation:  operation,
		Direction:  direction,
		Path:       path,
		Policy: remoteaccess.FileTransferPolicy{
			AllowedOperations: []remoteaccess.FileTransferOperation{operation},
			AllowedPathRules:  []string{target.RemoteDir},
			MaxFiles:          10,
			MaxBytes:          1024,
		},
		Approved: true,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}

	return &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: remoteaccess.FrameTypeFileTransferRequest,
		Data:      data,
	}
}

func integrationFileTransferDataFrame(
	t *testing.T,
	target integrationSSHTarget,
	sequence uint64,
	offset int64,
	data []byte,
	eof bool,
) *proto.ConsoleFrame {
	t.Helper()

	payload := remoteaccess.FileTransferDataPayload{
		TransferID: "integration-upload",
		Sequence:   sequence,
		Offset:     offset,
		Data:       data,
		EOF:        eof,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}

	return &proto.ConsoleFrame{
		SessionId: target.SessionID,
		FrameType: remoteaccess.FrameTypeFileTransferData,
		Data:      encoded,
	}
}

func assertIntegrationFileTransferOutcome(
	t *testing.T,
	sender *fakeProxmoxConsoleSender,
	status remoteaccess.FileTransferStatus,
	bytesTransferred int64,
	timeout time.Duration,
) {
	t.Helper()

	frame := nextIntegrationFrame(t, sender, remoteaccess.FrameTypeFileTransferOutcome, timeout)
	var payload remoteaccess.FileTransferOutcomePayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		t.Fatalf("decode file-transfer outcome: %v", err)
	}
	if payload.Status != status {
		t.Fatalf("file-transfer status = %q, want %q", payload.Status, status)
	}
	if payload.BytesTransferred != bytesTransferred {
		t.Fatalf("bytes_transferred = %d, want %d", payload.BytesTransferred, bytesTransferred)
	}
}

func assertIntegrationDownloadPayload(
	t *testing.T,
	sender *fakeProxmoxConsoleSender,
	expected string,
	timeout time.Duration,
) {
	t.Helper()

	var output bytes.Buffer
	deadline := time.After(timeout)
	for {
		select {
		case frame := <-sender.ch:
			switch frame.GetFrameType() {
			case remoteaccess.FrameTypeFileTransferData:
				var payload remoteaccess.FileTransferDataPayload
				if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
					t.Fatalf("decode file-transfer data: %v", err)
				}
				_, _ = output.Write(payload.Data)
				if payload.EOF {
					if output.String() != expected {
						t.Fatalf("download payload = %q, want %q", output.String(), expected)
					}
					return
				}
			case remoteaccess.FrameTypeFileTransferError:
				t.Fatalf("received file-transfer error: %s", string(frame.GetData()))
			}
		case <-deadline:
			t.Fatalf("timed out waiting for download payload\noutput:\n%s", output.String())
		}
	}
}

func nextIntegrationFrame(
	t *testing.T,
	sender *fakeProxmoxConsoleSender,
	frameType string,
	timeout time.Duration,
) *proto.ConsoleFrame {
	t.Helper()

	deadline := time.After(timeout)
	for {
		select {
		case frame := <-sender.ch:
			if frame.GetFrameType() == frameType {
				return frame
			}
			if frame.GetFrameType() == consoleFrameTypeError {
				t.Fatalf("received error frame while waiting for %q: %s", frameType, frame.GetReason())
			}
			if frame.GetFrameType() == remoteaccess.FrameTypeFileTransferError {
				t.Fatalf("received file-transfer error while waiting for %q: %s", frameType, string(frame.GetData()))
			}
		case <-deadline:
			t.Fatalf("timed out waiting for console frame type %q", frameType)
		}
	}
}

type integrationSSHTarget struct {
	Host         string
	Port         int
	Username     string
	Principal    string
	AgentID      string
	SessionID    string
	RemoteDir    string
	CAPrivateKey []byte
}

func integrationSSHTargetFromEnv(t *testing.T) integrationSSHTarget {
	t.Helper()

	host := strings.TrimSpace(os.Getenv("SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_HOST"))
	if host == "" {
		return integrationSSHTarget{}
	}

	port, err := strconv.Atoi(envDefault("SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT", "22"))
	if err != nil || port <= 0 {
		t.Fatalf("invalid SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT: %q", os.Getenv("SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_PORT"))
	}

	caKeyPath := strings.TrimSpace(os.Getenv("SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE"))
	if caKeyPath == "" {
		t.Fatal("SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE is required when SERVICERADAR_REMOTE_ACCESS_SSH_TARGET_HOST is set")
	}

	caKey, err := os.ReadFile(caKeyPath)
	if err != nil {
		t.Fatalf("read SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_FILE: %v", err)
	}

	return integrationSSHTarget{
		Host:         host,
		Port:         port,
		Username:     envDefault("SERVICERADAR_REMOTE_ACCESS_SSH_USERNAME", "srtest"),
		Principal:    envDefault("SERVICERADAR_REMOTE_ACCESS_SSH_PRINCIPAL", "sr-test-operator"),
		AgentID:      envDefault("SERVICERADAR_REMOTE_ACCESS_AGENT_ID", "demo-agent"),
		SessionID:    envDefault("SERVICERADAR_REMOTE_ACCESS_SESSION_ID", "demo-agent-sshca-session"),
		RemoteDir:    strings.TrimRight(os.Getenv("SERVICERADAR_REMOTE_ACCESS_SSH_TEST_DIR"), "/"),
		CAPrivateKey: caKey,
	}
}

func startLocalTrustedUserCATarget(t *testing.T) integrationSSHTarget {
	t.Helper()

	sshdPath := requireAgentIntegrationCommand(t, "sshd")
	sshKeygenPath := requireAgentIntegrationCommand(t, "ssh-keygen")
	username := currentIntegrationUsername(t)
	tmpDir := t.TempDir()
	remoteDir := filepath.Join(tmpDir, "remote")
	if err := os.Mkdir(remoteDir, 0o700); err != nil {
		t.Fatalf("create remote dir: %v", err)
	}

	caKeyPath := filepath.Join(tmpDir, "ca_ed25519")
	hostKeyPath := filepath.Join(tmpDir, "host_ed25519")
	runAgentIntegrationTool(t, sshKeygenPath, "-t", "ed25519", "-N", "", "-f", caKeyPath)
	runAgentIntegrationTool(t, sshKeygenPath, "-t", "ed25519", "-N", "", "-f", hostKeyPath)

	caPubPath := filepath.Join(tmpDir, "trusted_user_ca.pub")
	principalsPath := filepath.Join(tmpDir, "authorized_principals")
	writeAgentIntegrationFile(t, caPubPath, readAgentIntegrationFile(t, caKeyPath+".pub"), 0o644)
	writeAgentIntegrationFile(t, principalsPath, []byte("sr-test-operator\n"), 0o644)

	port := freeAgentIntegrationPort(t)
	configPath := filepath.Join(tmpDir, "sshd_config")
	writeAgentIntegrationFile(t, configPath, []byte(fmt.Sprintf(`
Port %d
ListenAddress 127.0.0.1
HostKey %s
PidFile %s
AuthorizedKeysFile none
AuthorizedPrincipalsFile %s
TrustedUserCAKeys %s
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
Subsystem sftp internal-sftp
UsePAM no
PermitTTY yes
StrictModes no
AllowUsers %s
LogLevel VERBOSE
`, port, hostKeyPath, filepath.Join(tmpDir, "sshd.pid"), principalsPath, caPubPath, username)), 0o600)

	verifyAgentSSHDConfig(t, sshdPath, configPath)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	var sshdLog bytes.Buffer
	sshd := exec.CommandContext(ctx, sshdPath, "-D", "-e", "-f", configPath)
	sshd.Stdout = &sshdLog
	sshd.Stderr = &sshdLog
	if err := sshd.Start(); err != nil {
		t.Fatalf("start sshd: %v", err)
	}
	t.Cleanup(func() {
		cancel()
		_ = sshd.Wait()
	})
	waitForAgentIntegrationTCP(t, "127.0.0.1", port, &sshdLog)

	return integrationSSHTarget{
		Host:         "127.0.0.1",
		Port:         port,
		Username:     username,
		Principal:    "sr-test-operator",
		AgentID:      "agent-1",
		SessionID:    "agent-routed-sshca-session",
		RemoteDir:    remoteDir,
		CAPrivateKey: readAgentIntegrationFile(t, caKeyPath),
	}
}

func generateIntegrationUserKey(t *testing.T) ([]byte, []byte) {
	t.Helper()

	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate user key: %v", err)
	}

	privateKeyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal user private key: %v", err)
	}
	privateKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKeyDER})

	sshPublicKey, err := ssh.NewPublicKey(publicKey)
	if err != nil {
		t.Fatalf("marshal user public key: %v", err)
	}

	return privateKeyPEM, ssh.MarshalAuthorizedKey(sshPublicKey)
}

func envDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func requireAgentIntegrationCommand(t *testing.T, name string) string {
	t.Helper()

	path, err := exec.LookPath(name)
	if err != nil {
		t.Skipf("%s is unavailable: %v", name, err)
	}
	return path
}

func currentIntegrationUsername(t *testing.T) string {
	t.Helper()

	currentUser, err := user.Current()
	if err != nil {
		t.Skipf("current user unavailable: %v", err)
	}

	username := currentUser.Username
	if idx := strings.LastIndexAny(username, `/\`); idx >= 0 {
		username = username[idx+1:]
	}
	username = strings.TrimSpace(username)
	if username == "" {
		t.Skip("current username is empty")
	}
	return username
}

func runAgentIntegrationTool(t *testing.T, name string, args ...string) {
	t.Helper()

	cmd := exec.Command(name, args...)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("%s %s failed: %v\n%s", name, strings.Join(args, " "), err, output.String())
	}
}

func readAgentIntegrationFile(t *testing.T, path string) []byte {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return data
}

func writeAgentIntegrationFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()

	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func verifyAgentSSHDConfig(t *testing.T, sshdPath, configPath string) {
	t.Helper()

	cmd := exec.Command(sshdPath, "-t", "-f", configPath)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		t.Skipf("sshd cannot use temporary integration config: %v\n%s", err, output.String())
	}
}

func freeAgentIntegrationPort(t *testing.T) int {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate local port: %v", err)
	}
	defer listener.Close()

	return listener.Addr().(*net.TCPAddr).Port
}

func waitForAgentIntegrationTCP(t *testing.T, host string, port int, sshdLog *bytes.Buffer) {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	address := fmt.Sprintf("%s:%d", host, port)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}

	t.Fatalf("sshd did not listen on %s\nsshd:\n%s", address, sshdLog.String())
}
