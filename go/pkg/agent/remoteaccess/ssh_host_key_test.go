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
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

const hostKeyTestAddress = "host01.example.com:2222"

func hostKeyTestSigner(t *testing.T) ssh.Signer {
	t.Helper()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}

	return signer
}

func hostKeyTestRemote() net.Addr {
	return &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 2222}
}

// A first connection to a host that has never been enrolled must name the
// target and the offered key so the console can offer trust-on-first-use.
// Before this, the operator saw only "knownhosts: key is unknown".
func TestKnownHostsPolicyReportsUnknownHostKeyWithFingerprint(t *testing.T) {
	t.Parallel()

	signer := hostKeyTestSigner(t)
	knownHostsPath := filepath.Join(t.TempDir(), "known_hosts")

	callback, err := sshHostKeyCallback("known_hosts", knownHostsPath)
	if err != nil {
		t.Fatalf("known_hosts callback: %v", err)
	}

	err = callback(hostKeyTestAddress, hostKeyTestRemote(), signer.PublicKey())
	if !errors.Is(err, ErrSSHHostKeyUnknown) {
		t.Fatalf("unknown host key error = %v, want %v", err, ErrSSHHostKeyUnknown)
	}
	if errors.Is(err, ErrSSHHostKeyMismatch) {
		t.Fatalf("unknown host key must not be reported as a mismatch: %v", err)
	}

	message := err.Error()
	for _, want := range []string{
		hostKeyTestAddress,
		signer.PublicKey().Type(),
		ssh.FingerprintSHA256(signer.PublicKey()),
		"trust-on-first-use",
	} {
		if !strings.Contains(message, want) {
			t.Fatalf("unknown host key message %q does not contain %q", message, want)
		}
	}
}

// A host that is already enrolled and then offers a different key is the
// man-in-the-middle case: it must stay distinguishable from first contact so
// the console never offers it for acceptance.
func TestKnownHostsPolicyReportsChangedHostKeyAsMismatch(t *testing.T) {
	t.Parallel()

	trusted := hostKeyTestSigner(t)
	offered := hostKeyTestSigner(t)
	knownHostsPath := filepath.Join(t.TempDir(), "known_hosts")
	line := knownhosts.Line([]string{knownhosts.Normalize(hostKeyTestAddress)}, trusted.PublicKey())
	if err := os.WriteFile(knownHostsPath, []byte(line+"\n"), 0o600); err != nil {
		t.Fatalf("write known_hosts: %v", err)
	}

	callback, err := sshHostKeyCallback("known_hosts", knownHostsPath)
	if err != nil {
		t.Fatalf("known_hosts callback: %v", err)
	}

	err = callback(hostKeyTestAddress, hostKeyTestRemote(), offered.PublicKey())
	if !errors.Is(err, ErrSSHHostKeyMismatch) {
		t.Fatalf("changed host key error = %v, want %v", err, ErrSSHHostKeyMismatch)
	}
	if errors.Is(err, ErrSSHHostKeyUnknown) {
		t.Fatalf("changed host key must not be reported as unknown: %v", err)
	}
	if strings.Contains(err.Error(), "trust-on-first-use") {
		t.Fatalf("changed host key message must not suggest trust-on-first-use: %q", err.Error())
	}
	if !strings.Contains(err.Error(), ssh.FingerprintSHA256(offered.PublicKey())) {
		t.Fatalf("changed host key message %q omits the offered fingerprint", err.Error())
	}
}

// trust_on_first_use pins first contact, so only its mismatch path classifies.
func TestTrustOnFirstUsePolicyReportsChangedHostKeyAsMismatch(t *testing.T) {
	t.Parallel()

	trusted := hostKeyTestSigner(t)
	offered := hostKeyTestSigner(t)
	knownHostsPath := filepath.Join(t.TempDir(), "known_hosts")
	line := knownhosts.Line([]string{knownhosts.Normalize(hostKeyTestAddress)}, trusted.PublicKey())
	if err := os.WriteFile(knownHostsPath, []byte(line+"\n"), 0o600); err != nil {
		t.Fatalf("write known_hosts: %v", err)
	}

	callback, err := sshHostKeyCallback("trust_on_first_use", knownHostsPath)
	if err != nil {
		t.Fatalf("trust_on_first_use callback: %v", err)
	}

	err = callback(hostKeyTestAddress, hostKeyTestRemote(), offered.PublicKey())
	if !errors.Is(err, ErrSSHHostKeyMismatch) {
		t.Fatalf("changed TOFU key error = %v, want %v", err, ErrSSHHostKeyMismatch)
	}
}

// A verification success and a non-verification failure must both pass through
// untouched; classification only ever renames a knownhosts.KeyError.
func TestClassifySSHHostKeyErrorLeavesOtherResultsAlone(t *testing.T) {
	t.Parallel()

	signer := hostKeyTestSigner(t)

	if err := classifySSHHostKeyError(hostKeyTestAddress, signer.PublicKey(), nil); err != nil {
		t.Fatalf("classified nil error = %v, want nil", err)
	}

	storeErr := &os.PathError{Op: "read", Path: "known_hosts", Err: os.ErrPermission}
	if err := classifySSHHostKeyError(hostKeyTestAddress, signer.PublicKey(), storeErr); !errors.Is(err, storeErr) {
		t.Fatalf("classified store error = %v, want %v", err, storeErr)
	}
}

func TestSSHReviewedHostKeyApproval(t *testing.T) {
	approved := hostKeyTestSigner(t).PublicKey()
	other := hostKeyTestSigner(t).PublicKey()
	for _, tc := range []struct {
		name         string
		target       string
		fingerprint  string
		offered      ssh.PublicKey
		pinned       ssh.PublicKey
		wantMismatch bool
	}{
		{name: "reviewed key", target: hostKeyTestAddress, fingerprint: ssh.FingerprintSHA256(approved), offered: approved},
		{name: "key changed during retry", target: hostKeyTestAddress, fingerprint: ssh.FingerprintSHA256(approved), offered: other, wantMismatch: true},
		{name: "target changed during retry", target: "host02.example.com:2222", fingerprint: ssh.FingerprintSHA256(approved), offered: approved, wantMismatch: true},
		{name: "port changed during retry", target: "host01.example.com:22", fingerprint: ssh.FingerprintSHA256(approved), offered: approved, wantMismatch: true},
		{name: "missing fingerprint", target: hostKeyTestAddress, offered: approved, wantMismatch: true},
		{name: "missing target", fingerprint: ssh.FingerprintSHA256(approved), offered: approved, wantMismatch: true},
		{name: "already pinned different key", target: hostKeyTestAddress, fingerprint: ssh.FingerprintSHA256(approved), offered: approved, pinned: other, wantMismatch: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "known_hosts")
			initial := ""
			if tc.pinned != nil {
				initial = knownhosts.Line([]string{knownhosts.Normalize(hostKeyTestAddress)}, tc.pinned) + "\n"
			}
			if err := os.WriteFile(path, []byte(initial), 0o600); err != nil {
				t.Fatal(err)
			}
			cfg, err := SSHConfigFromOpenFrame(Frame{Protocol: ProtocolSSH, Data: mustSSHOpenPayload(t, SSHOpenPayload{
				Target:             SSHTarget{Host: "host01.example.com", Port: 2222},
				SSHHostKeyPolicy:   "known_hosts",
				SSHHostKeyApproval: &SSHHostKeyApproval{Target: tc.target, Fingerprint: tc.fingerprint},
			})})
			if err != nil {
				t.Fatal(err)
			}
			cfg.KnownHostsPath = path
			callback, err := sshSessionHostKeyCallback(cfg)
			if err != nil {
				t.Fatal(err)
			}
			err = callback(hostKeyTestAddress, hostKeyTestRemote(), tc.offered)
			if tc.wantMismatch {
				if !errors.Is(err, ErrSSHHostKeyMismatch) || errors.Is(err, ErrSSHHostKeyUnknown) {
					t.Fatalf("approval failure = %v, want mismatch", err)
				}
				data, readErr := os.ReadFile(path)
				if readErr != nil {
					t.Fatal(readErr)
				}
				if string(data) != initial {
					t.Fatal("rejected approval changed the known-hosts store")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				verify, err := knownHostsCallback(path)
				if err != nil {
					t.Fatal(err)
				}
				if err := verify(hostKeyTestAddress, hostKeyTestRemote(), approved); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
