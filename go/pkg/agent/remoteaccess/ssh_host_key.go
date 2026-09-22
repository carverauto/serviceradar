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
	"errors"
	"fmt"
	"net"
	"strings"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

// Host-key verification failures reach the operator as a session close reason,
// which is the only channel the console frame vocabulary offers. The two
// classes below therefore carry a stable, documented sentence shape so the
// browser can tell an enrollable first contact apart from a key that changed
// under a host that was already trusted. Only the first is ever offered for
// acceptance; the second is the man-in-the-middle case and stays a hard close.
var (
	// ErrSSHHostKeyUnknown reports that no entry exists yet for the target in
	// the agent-local known-hosts store. The operator can review the offered
	// fingerprint and enroll it with the trust-on-first-use policy.
	ErrSSHHostKeyUnknown = errors.New("ssh host key is not trusted")

	// ErrSSHHostKeyMismatch reports that the target offered a key that differs
	// from the one already pinned for it or from an explicit retry approval.
	ErrSSHHostKeyMismatch = errors.New("ssh host key does not match the trusted entry")
)

const (
	sshHostKeyUnknownDetail = "%w: %s offered %s %s and the agent known-hosts store has no entry for it; " +
		"review the fingerprint, then reconnect with the trust-on-first-use host key policy to pin it"

	sshHostKeyMismatchDetail = "%w: %s offered %s %s but the agent known-hosts store holds a different key " +
		"for it; verify the change out of band before trusting this host again"
)

// classifySSHHostKeyError converts a known-hosts verification failure into an
// operator-actionable error that names the target and the offered key.
//
// x/crypto reports both "never seen this host" and "this host changed its key"
// as the same knownhosts.KeyError, distinguished only by whether Want is empty,
// and its messages ("knownhosts: key is unknown" or "knownhosts: key mismatch")
// name neither the host nor the key. Both facts are needed at the console to
// make the failure recoverable without inviting a blind accept of a changed key.
// Errors that are
// not host-key verification failures (a revoked key, a store read error, a
// transport failure) are returned unchanged.
func classifySSHHostKeyError(hostname string, key ssh.PublicKey, err error) error {
	if err == nil {
		return nil
	}

	var keyErr *knownhosts.KeyError
	if !errors.As(err, &keyErr) {
		return err
	}

	target := sshHostKeyTargetLabel(hostname)
	fingerprint := ssh.FingerprintSHA256(key)

	if len(keyErr.Want) == 0 {
		return fmt.Errorf(sshHostKeyUnknownDetail, ErrSSHHostKeyUnknown, target, key.Type(), fingerprint)
	}

	return fmt.Errorf(sshHostKeyMismatchDetail, ErrSSHHostKeyMismatch, target, key.Type(), fingerprint)
}

// sshHostKeyTargetLabel renders the dialed address for the operator. The
// callback receives the address handed to ssh.NewClientConn, which is already
// host:port. An empty one would leave a hole in the sentence and shift every
// following field by one word, so it degrades to a two-word placeholder: the
// sentence still reads, and the browser's classifier declines to match it
// rather than reporting a fabricated target back to the operator.
func sshHostKeyTargetLabel(hostname string) string {
	if label := strings.TrimSpace(hostname); label != "" {
		return label
	}

	return "the target"
}

// verifiedSSHHostKeyCallback wraps a host-key callback so every verification
// failure it reports is classified before it leaves the agent.
func verifiedSSHHostKeyCallback(callback ssh.HostKeyCallback) ssh.HostKeyCallback {
	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		return classifySSHHostKeyError(hostname, key, callback(hostname, remote, key))
	}
}

type SSHHostKeyApproval struct {
	Target      string `json:"target"`
	Fingerprint string `json:"fingerprint"`
}

func sshSessionHostKeyCallback(cfg SSHConfig) (ssh.HostKeyCallback, error) {
	if cfg.SSHHostKeyApproval == nil {
		return sshHostKeyCallback(cfg.SSHHostKeyPolicy, cfg.KnownHostsPath)
	}
	approval := *cfg.SSHHostKeyApproval
	callback, err := trustOnFirstUseCallback(cfg.KnownHostsPath)
	if err != nil {
		return nil, err
	}
	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		if hostname != approval.Target || ssh.FingerprintSHA256(key) != approval.Fingerprint {
			return fmt.Errorf("%w: %s offered %s %s but it does not match the approved target and fingerprint",
				ErrSSHHostKeyMismatch, sshHostKeyTargetLabel(hostname), key.Type(), ssh.FingerprintSHA256(key))
		}
		return callback(hostname, remote, key)
	}, nil
}
