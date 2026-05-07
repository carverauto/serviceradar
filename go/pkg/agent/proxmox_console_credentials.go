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
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

var (
	errProxmoxConsoleCredentialBrokerUnavailable = errors.New("proxmox console credential broker unavailable")
	errProxmoxConsoleCredentialNotFound          = errors.New("agent-local proxmox console credential not found")
	errProxmoxConsoleCredentialFileInsecure      = errors.New("agent-local proxmox console credential file permissions are too broad")
)

type proxmoxConsoleCredentialResolver interface {
	ResolveProxmoxConsoleSSHCredential(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHAuth, error)
}

type proxmoxConsoleLocalCredentialResolver struct {
	path string
}

type proxmoxConsoleLocalCredentialFile struct {
	Version     int                             `json:"version,omitempty"`
	Credentials []proxmoxConsoleLocalCredential `json:"credentials"`
}

type proxmoxConsoleLocalCredential struct {
	CredentialRuleID    string `json:"credential_rule_id,omitempty"`
	CredentialSecretRef string `json:"credential_secret_ref,omitempty"`
	AuthMethod          string `json:"auth_method,omitempty"`
	Username            string `json:"username,omitempty"`
	Password            string `json:"password,omitempty"`
	PrivateKey          string `json:"private_key,omitempty"`
	Passphrase          string `json:"passphrase,omitempty"`
}

func newProxmoxConsoleLocalCredentialResolver(path string) proxmoxConsoleCredentialResolver {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	return proxmoxConsoleLocalCredentialResolver{path: strings.TrimSpace(path)}
}

func (r proxmoxConsoleLocalCredentialResolver) ResolveProxmoxConsoleSSHCredential(
	_ context.Context,
	cfg proxmoxConsoleSSHConfig,
) (proxmoxConsoleSSHAuth, error) {
	if strings.TrimSpace(r.path) == "" {
		return proxmoxConsoleSSHAuth{}, errProxmoxConsoleCredentialBrokerUnavailable
	}

	broker := proxmoxConsoleCredentialBroker(cfg)
	if broker.CredentialRuleID == "" && broker.CredentialSecretRef == "" {
		return proxmoxConsoleSSHAuth{}, errProxmoxConsoleCredentialBrokerUnavailable
	}

	payload, err := loadProxmoxConsoleLocalCredentialFile(r.path)
	if err != nil {
		return proxmoxConsoleSSHAuth{}, err
	}

	for _, credential := range payload.Credentials {
		if !credential.matches(broker) {
			continue
		}
		auth := credential.sshAuth()
		if _, err := validateProxmoxConsoleSSHCredential(auth); err != nil {
			return proxmoxConsoleSSHAuth{}, err
		}
		return auth, nil
	}

	return proxmoxConsoleSSHAuth{}, errProxmoxConsoleCredentialNotFound
}

func loadProxmoxConsoleLocalCredentialFile(path string) (proxmoxConsoleLocalCredentialFile, error) {
	info, err := os.Stat(path)
	if err != nil {
		return proxmoxConsoleLocalCredentialFile{}, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return proxmoxConsoleLocalCredentialFile{}, fmt.Errorf("%w: %s must be readable only by the agent user", errProxmoxConsoleCredentialFileInsecure, path)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return proxmoxConsoleLocalCredentialFile{}, err
	}

	var payload proxmoxConsoleLocalCredentialFile
	if err := json.Unmarshal(data, &payload); err != nil {
		return proxmoxConsoleLocalCredentialFile{}, err
	}
	return payload, nil
}

type proxmoxConsoleCredentialBrokerGrant struct {
	CredentialRuleID    string
	CredentialSecretRef string
	AuthMethod          string
}

func proxmoxConsoleCredentialBroker(cfg proxmoxConsoleSSHConfig) proxmoxConsoleCredentialBrokerGrant {
	broker := cfg.CredentialBroker
	return proxmoxConsoleCredentialBrokerGrant{
		CredentialRuleID: firstNonEmpty(
			stringMapValue(broker, "credential_rule_id"),
			cfg.CredentialRuleID,
			cfg.Console.CredentialRuleID,
		),
		CredentialSecretRef: stringMapValue(broker, "credential_secret_ref"),
		AuthMethod: firstNonEmpty(
			stringMapValue(broker, "auth_method"),
			"ssh_private_key",
		),
	}
}

func (c proxmoxConsoleLocalCredential) matches(grant proxmoxConsoleCredentialBrokerGrant) bool {
	if grant.CredentialSecretRef != "" && strings.TrimSpace(c.CredentialSecretRef) == grant.CredentialSecretRef {
		return credentialAuthMethodMatches(c.AuthMethod, grant.AuthMethod)
	}
	if grant.CredentialRuleID != "" && strings.TrimSpace(c.CredentialRuleID) == grant.CredentialRuleID {
		return credentialAuthMethodMatches(c.AuthMethod, grant.AuthMethod)
	}
	return false
}

func credentialAuthMethodMatches(local, grant string) bool {
	local = strings.TrimSpace(local)
	grant = strings.TrimSpace(grant)
	return local == "" || grant == "" || local == grant
}

func (c proxmoxConsoleLocalCredential) sshAuth() proxmoxConsoleSSHAuth {
	return proxmoxConsoleSSHAuth{
		Username:   strings.TrimSpace(c.Username),
		Password:   c.Password,
		PrivateKey: c.PrivateKey,
		Passphrase: c.Passphrase,
	}
}

func stringMapValue(values map[string]any, key string) string {
	if values == nil {
		return ""
	}
	switch value := values[key].(type) {
	case string:
		return strings.TrimSpace(value)
	default:
		return ""
	}
}
