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

package remoteaccess

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/remoteaccess/sshca"
)

func TestOpenSSHFromFrameAuthenticatesWithServiceRadarCertificate(t *testing.T) {
	t.Parallel()

	sshdPath := requireIntegrationCommand(t, "sshd")
	sshKeygenPath := requireIntegrationCommand(t, "ssh-keygen")
	username := integrationUsername(t)
	tmpDir := t.TempDir()

	caKeyPath := filepath.Join(tmpDir, "ca_ed25519")
	userKeyPath := filepath.Join(tmpDir, "user_ed25519")
	hostKeyPath := filepath.Join(tmpDir, "host_ed25519")

	runIntegrationTool(t, sshKeygenPath, "-t", "ed25519", "-N", "", "-f", caKeyPath)
	runIntegrationTool(t, sshKeygenPath, "-t", "ed25519", "-N", "", "-f", userKeyPath)
	runIntegrationTool(t, sshKeygenPath, "-t", "ed25519", "-N", "", "-f", hostKeyPath)

	ca, err := sshca.New(readIntegrationFile(t, caKeyPath), nil, sshca.WithMaxTTL(time.Hour))
	if err != nil {
		t.Fatalf("initialize ServiceRadar SSH CA: %v", err)
	}

	signed, err := ca.SignUserCertificate(sshca.UserCertificateRequest{
		PublicKey:  readIntegrationFile(t, userKeyPath+".pub"),
		KeyID:      "sr:remote-access:session-1:user-1:agent-1:ssh:target-1",
		Principals: []string{"sr-test-operator"},
		TTL:        5 * time.Minute,
		Serial:     42,
	})
	if err != nil {
		t.Fatalf("sign user certificate: %v", err)
	}

	caPubPath := filepath.Join(tmpDir, "trusted_user_ca.pub")
	principalsPath := filepath.Join(tmpDir, "authorized_principals")
	writeIntegrationFile(t, caPubPath, readIntegrationFile(t, caKeyPath+".pub"), 0o644)
	writeIntegrationFile(t, principalsPath, []byte("sr-test-operator\n"), 0o644)

	port := freeIntegrationPort(t)
	configPath := filepath.Join(tmpDir, "sshd_config")
	writeIntegrationFile(t, configPath, []byte(fmt.Sprintf(`
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
UsePAM no
PermitTTY yes
StrictModes no
AllowUsers %s
LogLevel VERBOSE
`, port, hostKeyPath, filepath.Join(tmpDir, "sshd.pid"), principalsPath, caPubPath, username)), 0o600)

	verifyIntegrationSSHDConfig(t, sshdPath, configPath)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var sshdLog bytes.Buffer
	sshd := exec.CommandContext(ctx, sshdPath, "-D", "-e", "-f", configPath)
	sshd.Stdout = &sshdLog
	sshd.Stderr = &sshdLog
	if err := sshd.Start(); err != nil {
		t.Fatalf("start sshd: %v", err)
	}
	defer func() {
		cancel()
		_ = sshd.Wait()
	}()
	waitForIntegrationTCP(t, "127.0.0.1", port, &sshdLog)

	payload := SSHOpenPayload{
		Protocol:       ProtocolSSH,
		SessionID:      "session-1",
		AgentID:        "agent-1",
		Target:         SSHTarget{Host: "127.0.0.1", Port: port},
		CredentialMode: SSHCredentialModeSSHCertificate,
		SSH: SSHAuth{
			Username:    username,
			PrivateKey:  string(readIntegrationFile(t, userKeyPath)),
			Certificate: string(signed.AuthorizedKey),
		},
		SSHHostKeyPolicy: "skip_verify",
	}
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	pty, err := OpenSSHFromFrame(ctx, Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data:      data,
		Cols:      100,
		Rows:      30,
		Metadata:  map[string]string{"agent_id": "agent-1"},
	}, SSHOpenOptions{})
	if err != nil {
		t.Fatalf("OpenSSHFromFrame returned error: %v\nsshd:\n%s", err, sshdLog.String())
	}
	defer func() { _ = pty.Close() }()

	if err := pty.Write([]byte("printf serviceradar-agent-sshca\\n; exit\n")); err != nil {
		t.Fatalf("write command: %v", err)
	}

	readCtx, readCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer readCancel()

	var output bytes.Buffer
	for !strings.Contains(output.String(), "serviceradar-agent-sshca") {
		chunk, err := pty.Read(readCtx)
		if len(chunk) > 0 {
			_, _ = output.Write(chunk)
		}
		if err != nil {
			t.Fatalf("read PTY output before marker: %v\noutput:\n%s\nsshd:\n%s",
				err, output.String(), sshdLog.String())
		}
	}
}

func requireIntegrationCommand(t *testing.T, name string) string {
	t.Helper()

	path, err := exec.LookPath(name)
	if err != nil {
		t.Skipf("%s is unavailable: %v", name, err)
	}
	return path
}

func integrationUsername(t *testing.T) string {
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

func runIntegrationTool(t *testing.T, name string, args ...string) {
	t.Helper()

	cmd := exec.Command(name, args...)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("%s %s failed: %v\n%s", name, strings.Join(args, " "), err, output.String())
	}
}

func readIntegrationFile(t *testing.T, path string) []byte {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return data
}

func writeIntegrationFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()

	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func verifyIntegrationSSHDConfig(t *testing.T, sshdPath, configPath string) {
	t.Helper()

	cmd := exec.Command(sshdPath, "-t", "-f", configPath)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		t.Skipf("sshd cannot use temporary integration config: %v\n%s", err, output.String())
	}
}

func freeIntegrationPort(t *testing.T) int {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate local port: %v", err)
	}
	defer listener.Close()

	return listener.Addr().(*net.TCPAddr).Port
}

func waitForIntegrationTCP(t *testing.T, host string, port int, sshdLog *bytes.Buffer) {
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
