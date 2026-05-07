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
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestProxmoxConsoleLocalCredentialResolverMatchesBrokerGrant(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxmox-console-credentials.json")
	if err := os.WriteFile(path, []byte(`{
	  "version": 1,
	  "credentials": [{
	    "credential_rule_id": "rule-1",
	    "credential_secret_ref": "credentialref:network-credential-secret:secret-1",
	    "auth_method": "ssh_private_key",
	    "username": "root",
	    "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----"
	  }]
	}`), 0o600); err != nil {
		t.Fatalf("write credential file: %v", err)
	}

	resolver := newProxmoxConsoleLocalCredentialResolver(path)
	credential, err := resolver.ResolveProxmoxConsoleSSHCredential(context.Background(), proxmoxConsoleSSHConfig{
		CredentialBroker: map[string]any{
			"credential_rule_id":    "rule-1",
			"credential_secret_ref": "credentialref:network-credential-secret:secret-1",
			"auth_method":           "ssh_private_key",
		},
	})
	if err != nil {
		t.Fatalf("ResolveProxmoxConsoleSSHCredential returned error: %v", err)
	}
	if credential.Username != "root" || credential.PrivateKey == "" {
		t.Fatalf("unexpected credential: %#v", credential)
	}
}

func TestProxmoxConsoleLocalCredentialResolverRejectsBroadPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxmox-console-credentials.json")
	if err := os.WriteFile(path, []byte(`{"credentials":[]}`), 0o644); err != nil {
		t.Fatalf("write credential file: %v", err)
	}

	resolver := newProxmoxConsoleLocalCredentialResolver(path)
	_, err := resolver.ResolveProxmoxConsoleSSHCredential(context.Background(), proxmoxConsoleSSHConfig{
		CredentialBroker: map[string]any{"credential_rule_id": "rule-1"},
	})
	if !errors.Is(err, errProxmoxConsoleCredentialFileInsecure) {
		t.Fatalf("expected insecure file permissions error, got %v", err)
	}
}

func TestProxmoxConsoleLocalCredentialResolverRequiresBrokerGrant(t *testing.T) {
	resolver := newProxmoxConsoleLocalCredentialResolver(filepath.Join(t.TempDir(), "missing.json"))
	_, err := resolver.ResolveProxmoxConsoleSSHCredential(context.Background(), proxmoxConsoleSSHConfig{})
	if !errors.Is(err, errProxmoxConsoleCredentialBrokerUnavailable) {
		t.Fatalf("expected broker unavailable error, got %v", err)
	}
}

func TestNewPluginManagerConfiguresProxmoxConsoleCredentialResolver(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proxmox-console-credentials.json")
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		ProxmoxConsoleCredentialsFile: path,
	})

	if manager.proxmoxConsoleCredentialResolver == nil {
		t.Fatalf("expected local credential resolver")
	}
}

func TestServerProxmoxConsoleCredentialsFilePrecedence(t *testing.T) {
	configDir := t.TempDir()
	defaultPath := filepath.Join(configDir, "proxmox-console-credentials.json")
	if err := os.WriteFile(defaultPath, []byte(`{"credentials":[]}`), 0o600); err != nil {
		t.Fatalf("write default credential file: %v", err)
	}

	t.Setenv("SERVICERADAR_PROXMOX_CONSOLE_CREDENTIALS_FILE", "/env/proxmox-console-credentials.json")

	srv := &Server{
		configDir: configDir,
		config: &ServerConfig{
			ProxmoxConsoleCredentialsFile: "/config/proxmox-console-credentials.json",
		},
	}
	if got := srv.proxmoxConsoleCredentialsFile(); got != "/config/proxmox-console-credentials.json" {
		t.Fatalf("expected explicit config path, got %q", got)
	}

	srv.config.ProxmoxConsoleCredentialsFile = ""
	if got := srv.proxmoxConsoleCredentialsFile(); got != "/env/proxmox-console-credentials.json" {
		t.Fatalf("expected env path, got %q", got)
	}

	t.Setenv("SERVICERADAR_PROXMOX_CONSOLE_CREDENTIALS_FILE", "")
	if got := srv.proxmoxConsoleCredentialsFile(); got != defaultPath {
		t.Fatalf("expected default adjacent path, got %q", got)
	}
}

func TestProxmoxConsolePluginErrorCodeCredentialBrokerErrors(t *testing.T) {
	if got := proxmoxConsolePluginErrorCode(errProxmoxConsoleCredentialBrokerUnavailable); got != pluginErrDenied {
		t.Fatalf("expected denied for unavailable broker, got %d", got)
	}
	if got := proxmoxConsolePluginErrorCode(errProxmoxConsoleCredentialFileInsecure); got != pluginErrDenied {
		t.Fatalf("expected denied for insecure local credential file, got %d", got)
	}
	if got := proxmoxConsolePluginErrorCode(errProxmoxConsoleCredentialNotFound); got != pluginErrNotFound {
		t.Fatalf("expected not found for missing local credential, got %d", got)
	}
}
