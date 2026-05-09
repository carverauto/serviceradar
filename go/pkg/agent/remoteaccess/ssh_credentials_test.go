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
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestFileSSHCredentialResolverMatchesScopedCredential(t *testing.T) {
	t.Parallel()

	path := writeSSHCredentialFile(t, 0o600, `{
  "version": 1,
  "credentials": [
    {
      "credential_ref": "ssh/router-admin",
      "host": "router.example",
      "port": 2222,
      "username": "admin",
      "private_key": "agent-local-key",
      "passphrase": "secret"
    }
  ]
}`)

	auth, err := (FileSSHCredentialResolver{Path: path}).ResolveSSHCredential(context.Background(), SSHCredentialRequest{
		SessionID:     "session-1",
		CredentialRef: "ssh/router-admin",
		Target:        SSHTarget{Host: "router.example", Port: 2222},
		Username:      "admin",
	})
	if err != nil {
		t.Fatalf("ResolveSSHCredential returned error: %v", err)
	}
	if auth.Username != "admin" || auth.PrivateKey != "agent-local-key" || auth.Passphrase != "secret" {
		t.Fatalf("auth = %#v", auth)
	}
}

func TestFileSSHCredentialResolverRejectsBroadPermissions(t *testing.T) {
	t.Parallel()

	path := writeSSHCredentialFile(t, 0o644, `{"credentials":[]}`)

	_, err := (FileSSHCredentialResolver{Path: path}).ResolveSSHCredential(context.Background(), SSHCredentialRequest{
		CredentialRef: "ssh/router-admin",
	})
	if !errors.Is(err, ErrSSHCredentialFileInsecure) {
		t.Fatalf("error = %v, want %v", err, ErrSSHCredentialFileInsecure)
	}
}

func TestFileSSHCredentialResolverRequiresMatchingScope(t *testing.T) {
	t.Parallel()

	path := writeSSHCredentialFile(t, 0o600, `{
  "credentials": [
    {
      "credential_ref": "ssh/router-admin",
      "host": "router.example",
      "username": "admin",
      "password": "secret"
    }
  ]
}`)

	_, err := (FileSSHCredentialResolver{Path: path}).ResolveSSHCredential(context.Background(), SSHCredentialRequest{
		CredentialRef: "ssh/router-admin",
		Target:        SSHTarget{Host: "switch.example"},
		Username:      "admin",
	})
	if !errors.Is(err, ErrSSHCredentialNotFound) {
		t.Fatalf("host mismatch error = %v, want %v", err, ErrSSHCredentialNotFound)
	}

	_, err = (FileSSHCredentialResolver{Path: path}).ResolveSSHCredential(context.Background(), SSHCredentialRequest{
		CredentialRef: "ssh/router-admin",
		Target:        SSHTarget{Host: "router.example"},
		Username:      "operator",
	})
	if !errors.Is(err, ErrSSHCredentialNotFound) {
		t.Fatalf("username mismatch error = %v, want %v", err, ErrSSHCredentialNotFound)
	}
}

func writeSSHCredentialFile(t *testing.T, perm os.FileMode, content string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "ssh-credentials.json")
	if err := os.WriteFile(path, []byte(content), perm); err != nil {
		t.Fatalf("write credential file: %v", err)
	}
	if err := os.Chmod(path, perm); err != nil {
		t.Fatalf("chmod credential file: %v", err)
	}

	return path
}
