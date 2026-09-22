/*
 * Copyright 2026 Carver Automation Corporation.
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
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	pluginHostAuthoritySchema             = "serviceradar.plugin_host_authority.v1"
	pluginHostCredentialSentinel          = "__SERVICERADAR_HOST_CREDENTIAL__"
	proxmoxInventoryPluginID              = "proxmox-inventory"
	proxmoxInventoryEntrypoint            = "run_check"
	proxmoxInventoryPurpose               = "inventory_enrichment"
	proxmoxConsolePurpose                 = "console_access"
	proxmoxConsolePluginID                = "proxmox-console"
	proxmoxConsoleEntrypoint              = "run_console"
	proxmoxConsoleTicketSentinel          = "__SERVICERADAR_HOST_PROXMOX_TICKET__"
	proxmoxConsoleTicketTTL               = 30 * time.Second
	proxmoxAssignmentPolicyDomain         = "serviceradar.proxmox.assignment-policy.v1"
	proxmoxSSHHostKeyPolicyKnownHosts     = "known_hosts"
	proxmoxSSHHostKeyPolicyTrustFirstUse  = "trust_on_first_use"
	proxmoxProviderName                   = "proxmox"
	proxmoxObjectKindCluster              = "cluster"
	proxmoxObjectKindNode                 = "node"
	proxmoxObjectKindQEMU                 = "qemu"
	proxmoxObjectKindLXC                  = "lxc"
	proxmoxAPIStatusSegment               = "status"
	proxmoxAPIAgentSegment                = "agent"
	proxmoxResolutionLocationAgent        = "agent"
	proxmoxTargetKindQEMUGuest            = "qemu_guest"
	proxmoxTargetKindLXCGuest             = "lxc_guest"
	proxmoxTargetKindPVEHost              = "pve_host"
	maximumPluginHostAuthorityBindings    = 512
	maximumPluginHostAuthorityStringBytes = 4096
)

var (
	errPluginHostAuthorityDenied    = errors.New("plugin host authority request denied")
	errPluginHostAuthorityMalformed = errors.New("plugin host authority configuration is invalid")
)

var allowedPluginHostAuthorityTargetIDKeys = map[string]struct{}{ //nolint:gochecknoglobals
	"device_uid":              {},
	"integration_id":          {},
	"provider_ref":            {},
	proxmoxObjectKindNode:     {},
	proxmoxObjectKindCluster:  {},
	"vmid":                    {},
	"target_kind":             {},
	"controller_id":           {},
	"provider_instance_ref":   {},
	"native_cluster_id":       {},
	"object_kind":             {},
	"native_object_id":        {},
	"controller_device_uid":   {},
	"controller_provider_ref": {},
}

type pluginHostAuthorityEnvelope struct {
	Schema   string                               `json:"schema"`
	Bindings []pluginHostAuthorityEnvelopeBinding `json:"bindings"`
}

type pluginHostAuthorityEnvelopeBinding struct {
	BindingID                   string                `json:"binding_id"`
	Provider                    string                `json:"provider"`
	CredentialRuleID            string                `json:"credential_rule_id"`
	Origin                      string                `json:"origin"`
	InsecureSkipVerify          bool                  `json:"insecure_skip_verify"`
	AssignmentPolicyVersion     uint64                `json:"assignment_policy_version"`
	AssignmentPolicyFingerprint string                `json:"assignment_policy_fingerprint"`
	SSHHostKeyPolicy            string                `json:"ssh_host_key_policy,omitempty"`
	CABundlePEM                 string                `json:"ca_bundle_pem,omitempty"`
	ServerCertFingerprint       string                `json:"server_cert_fingerprint,omitempty"`
	CredentialBroker            credentialBrokerGrant `json:"credential_broker"`
	TargetIDs                   map[string]string     `json:"target_ids,omitempty"`
}

type pluginHostAuthorityBinding struct {
	bindingID                   string
	provider                    string
	credentialRuleID            string
	origin                      string
	insecureSkipVerify          bool
	assignmentPolicyVersion     uint64
	assignmentPolicyFingerprint string
	sshHostKeyPolicy            string
	caBundlePEM                 string
	serverCertFingerprint       string
	credentialBroker            credentialBrokerGrant
	targetIDs                   map[string]string
}

type pluginHostAuthorityStableBinding struct {
	BindingID                   string                `json:"binding_id"`
	Provider                    string                `json:"provider"`
	CredentialRuleID            string                `json:"credential_rule_id"`
	Origin                      string                `json:"origin"`
	InsecureSkipVerify          bool                  `json:"insecure_skip_verify"`
	AssignmentPolicyVersion     uint64                `json:"assignment_policy_version"`
	AssignmentPolicyFingerprint string                `json:"assignment_policy_fingerprint"`
	SSHHostKeyPolicy            string                `json:"ssh_host_key_policy,omitempty"`
	CABundlePEM                 string                `json:"ca_bundle_pem,omitempty"`
	ServerCertFingerprint       string                `json:"server_cert_fingerprint,omitempty"`
	CredentialBroker            credentialBrokerGrant `json:"credential_broker"`
	TargetIDs                   map[string]string     `json:"target_ids,omitempty"`
}

type proxmoxAssignmentPolicyBinding struct {
	PolicyID         string
	PolicyVersion    uint64
	CredentialRuleID string
	Fingerprint      string
}

type proxmoxConsoleTicketState struct {
	sessionID     string
	bindingID     string
	proxyPath     string
	websocketPath string
	port          string
	ticket        []byte
	expiresAt     time.Time
}

func isProxmoxHostAuthorityAssignment(pluginID, entrypoint string) bool {
	return (pluginID == proxmoxInventoryPluginID && entrypoint == proxmoxInventoryEntrypoint) ||
		(pluginID == proxmoxConsolePluginID && entrypoint == proxmoxConsoleEntrypoint)
}

// preparePluginHostAuthority validates the dedicated host-only protobuf field
// and the public Wasm configuration as one fail-closed unit. No compatibility
// path accepts an inline Proxmox secret: malformed or mixed-version input is
// replaced with an empty public config and receives no host authority.
func (a *pluginAssignment) preparePluginHostAuthority(hostParamsJSON []byte) error {
	if a == nil || !isProxmoxHostAuthorityAssignment(a.PluginID, a.Entrypoint) {
		return nil
	}

	a.proxmoxHostAuthorityRequired = true
	paramsJSON := append([]byte(nil), a.ParamsJSON...)
	hostJSON := append([]byte(nil), hostParamsJSON...)
	defer clear(paramsJSON)
	defer clear(hostJSON)

	fail := func() error {
		a.ParamsJSON = []byte("{}")
		a.replacePluginHostAuthority(nil, fingerprintPluginHostAuthorityInputs(paramsJSON, hostJSON))
		return errPluginHostAuthorityMalformed
	}

	if len(paramsJSON) == 0 || len(paramsJSON) > pluginMaxPayloadBytes ||
		len(hostJSON) == 0 || len(hostJSON) > pluginMaxPayloadBytes {
		return fail()
	}

	policyBinding, err := validateProxmoxPublicParams(
		paramsJSON,
		a.AssignmentID,
		a.PluginID,
		a.Entrypoint,
	)
	if err != nil {
		return fail()
	}

	bindings, err := decodePluginHostAuthority(hostJSON, a.PluginID, policyBinding)
	if err != nil {
		return fail()
	}

	a.replacePluginHostAuthority(bindings, fingerprintPluginHostAuthority(bindings))
	return nil
}

func decodePluginHostAuthority(
	raw []byte,
	pluginID string,
	policyBinding proxmoxAssignmentPolicyBinding,
) ([]pluginHostAuthorityBinding, error) {
	var envelope pluginHostAuthorityEnvelope
	if err := decodeStrictJSON(raw, &envelope); err != nil || envelope.Schema != pluginHostAuthoritySchema ||
		len(envelope.Bindings) == 0 || len(envelope.Bindings) > maximumPluginHostAuthorityBindings {
		return nil, errPluginHostAuthorityMalformed
	}

	bindings := make([]pluginHostAuthorityBinding, 0, len(envelope.Bindings))
	bindingIDs := make(map[string]struct{}, len(envelope.Bindings))
	scopes := make(map[string]struct{}, len(envelope.Bindings))

	for _, wire := range envelope.Bindings {
		binding, err := validatePluginHostAuthorityBinding(wire, pluginID, policyBinding)
		if err != nil {
			return nil, err
		}
		if _, duplicate := bindingIDs[binding.bindingID]; duplicate {
			return nil, errPluginHostAuthorityMalformed
		}
		bindingIDs[binding.bindingID] = struct{}{}

		scope := pluginHostAuthorityBindingScope(binding)
		if _, duplicate := scopes[scope]; duplicate {
			return nil, errPluginHostAuthorityMalformed
		}
		scopes[scope] = struct{}{}
		bindings = append(bindings, binding)
	}

	return bindings, nil
}

func validatePluginHostAuthorityBinding(
	wire pluginHostAuthorityEnvelopeBinding,
	pluginID string,
	policyBinding proxmoxAssignmentPolicyBinding,
) (pluginHostAuthorityBinding, error) {
	if !validPluginHostAuthorityString(wire.BindingID) || wire.Provider != proxmoxProviderName ||
		!validPluginHostAuthorityString(wire.CredentialRuleID) ||
		wire.CredentialRuleID != policyBinding.CredentialRuleID ||
		wire.AssignmentPolicyVersion != policyBinding.PolicyVersion ||
		wire.AssignmentPolicyFingerprint != policyBinding.Fingerprint ||
		!validProxmoxAssignmentPolicyFingerprint(wire.AssignmentPolicyFingerprint) ||
		!validProxmoxSSHHostKeyPolicy(wire.SSHHostKeyPolicy) {
		return pluginHostAuthorityBinding{}, errPluginHostAuthorityMalformed
	}

	origin, scheme, err := canonicalPluginHostAuthorityOrigin(wire.Origin)
	originURL, originParseErr := url.Parse(origin)
	if err != nil || originParseErr != nil || origin != wire.Origin || scheme != httpsScheme ||
		originURL == nil || net.ParseIP(originURL.Hostname()) == nil || wire.InsecureSkipVerify {
		return pluginHostAuthorityBinding{}, errPluginHostAuthorityMalformed
	}

	targetIDs, err := validatePluginHostAuthorityTargetIDs(wire.TargetIDs)
	if err != nil {
		return pluginHostAuthorityBinding{}, err
	}
	if pluginID == proxmoxConsolePluginID {
		if err := validateProxmoxConsoleBindingTargetIDs(targetIDs); err != nil {
			return pluginHostAuthorityBinding{}, err
		}
	}

	grant := cloneCredentialBrokerGrant(wire.CredentialBroker)
	if err := validatePluginHostAuthorityGrant(grant, pluginID, policyBinding.CredentialRuleID); err != nil {
		return pluginHostAuthorityBinding{}, err
	}
	if !validProxmoxSSHHostBindingPolicy(pluginID, wire.SSHHostKeyPolicy, grant) {
		return pluginHostAuthorityBinding{}, errPluginHostAuthorityMalformed
	}
	if !validPluginHostAuthorityCABundle(wire.CABundlePEM) ||
		!validPluginHostAuthorityFingerprint(wire.ServerCertFingerprint) ||
		(wire.CABundlePEM != "" && wire.ServerCertFingerprint != "") {
		return pluginHostAuthorityBinding{}, errPluginHostAuthorityMalformed
	}

	return pluginHostAuthorityBinding{
		bindingID:                   wire.BindingID,
		provider:                    wire.Provider,
		credentialRuleID:            wire.CredentialRuleID,
		origin:                      origin,
		insecureSkipVerify:          wire.InsecureSkipVerify,
		assignmentPolicyVersion:     wire.AssignmentPolicyVersion,
		assignmentPolicyFingerprint: wire.AssignmentPolicyFingerprint,
		sshHostKeyPolicy:            wire.SSHHostKeyPolicy,
		caBundlePEM:                 wire.CABundlePEM,
		serverCertFingerprint:       wire.ServerCertFingerprint,
		credentialBroker:            grant,
		targetIDs:                   targetIDs,
	}, nil
}

func validatePluginHostAuthorityGrant(grant credentialBrokerGrant, pluginID, credentialRuleID string) error {
	if grant.Schema != "serviceradar.edge_credential_broker_grant.v1" &&
		grant.Schema != "serviceradar.edge_credential_broker_grant.v2" {
		return errPluginHostAuthorityMalformed
	}
	if !validPluginHostAuthorityString(grant.GrantID) ||
		!validPluginHostAuthorityString(grant.CredentialSecretRef) ||
		grant.CredentialRuleID != credentialRuleID ||
		grant.ResolutionLocation != proxmoxResolutionLocationAgent && grant.ResolutionLocation != "hybrid" {
		return errPluginHostAuthorityMalformed
	}
	if grant.Consumer["kind"] != "plugin" || grant.Consumer["id"] != pluginID {
		return errPluginHostAuthorityMalformed
	}

	expectedPurpose := proxmoxInventoryPurpose
	if pluginID == proxmoxConsolePluginID {
		expectedPurpose = proxmoxConsolePurpose
	}
	if grant.Consumer["purpose"] != expectedPurpose {
		return errPluginHostAuthorityMalformed
	}
	if pluginID == proxmoxConsolePluginID {
		for _, path := range grant.Allow.Paths {
			if strings.Contains(path, "*") {
				return errPluginHostAuthorityMalformed
			}
		}
	}

	if err := validatePluginActionCredentialGrantEnvelope(grant, time.Now()); err != nil {
		return errPluginHostAuthorityMalformed
	}
	return nil
}

func validatePluginHostAuthorityTargetIDs(values map[string]string) (map[string]string, error) {
	if len(values) == 0 {
		return nil, nil
	}

	out := make(map[string]string, len(values))
	for key, value := range values {
		if _, allowed := allowedPluginHostAuthorityTargetIDKeys[key]; !allowed ||
			!validPluginHostAuthorityString(value) {
			return nil, errPluginHostAuthorityMalformed
		}
		switch key {
		case "vmid":
			if _, ok := parseStrictPositiveInt(value); !ok {
				return nil, errPluginHostAuthorityMalformed
			}
		case "target_kind":
			if proxmoxTargetKind(value) != value {
				return nil, errPluginHostAuthorityMalformed
			}
		case "object_kind":
			switch value {
			case proxmoxObjectKindCluster, proxmoxObjectKindNode, proxmoxObjectKindQEMU, proxmoxObjectKindLXC:
			default:
				return nil, errPluginHostAuthorityMalformed
			}
		}
		out[key] = value
	}
	if (out["object_kind"] == "") != (out["native_object_id"] == "") {
		return nil, errPluginHostAuthorityMalformed
	}
	return out, nil
}

func validateProxmoxConsoleBindingTargetIDs(targetIDs map[string]string) error {
	for _, key := range []string{
		"device_uid",
		"integration_id",
		"provider_ref",
		proxmoxObjectKindNode,
		"controller_id",
		"provider_instance_ref",
		"native_cluster_id",
		"object_kind",
		"native_object_id",
	} {
		if targetIDs[key] == "" {
			return errPluginHostAuthorityMalformed
		}
	}

	instance, ok := parseAgentProxmoxProviderInstanceRef(targetIDs["provider_instance_ref"])
	if !ok || !proxmoxConsoleSourceFieldsMatch(targetIDs, instance) {
		return errPluginHostAuthorityMalformed
	}

	subject, ok := parseAgentProxmoxProviderRef(targetIDs["provider_ref"])
	if !ok || !proxmoxConsoleSourceFieldsMatch(targetIDs, subject) ||
		subject.objectKind != targetIDs["object_kind"] ||
		subject.nativeObjectID != targetIDs["native_object_id"] {
		return errPluginHostAuthorityMalformed
	}

	switch targetIDs["object_kind"] {
	case proxmoxObjectKindNode:
		if targetIDs["target_kind"] != "" || targetIDs["vmid"] != "" ||
			targetIDs["controller_device_uid"] != "" || targetIDs["controller_provider_ref"] != "" ||
			subject.node != targetIDs[proxmoxObjectKindNode] ||
			targetIDs["native_object_id"] != targetIDs[proxmoxObjectKindNode] {
			return errPluginHostAuthorityMalformed
		}
	case proxmoxObjectKindQEMU, proxmoxObjectKindLXC:
		if targetIDs["controller_device_uid"] == "" || targetIDs["controller_provider_ref"] == "" ||
			targetIDs["target_kind"] != proxmoxTargetKind(targetIDs["object_kind"]) ||
			targetIDs["vmid"] != targetIDs["native_object_id"] {
			return errPluginHostAuthorityMalformed
		}
		controller, ok := parseAgentProxmoxProviderRef(targetIDs["controller_provider_ref"])
		if !ok || controller.objectKind != proxmoxObjectKindNode ||
			controller.node != targetIDs[proxmoxObjectKindNode] ||
			controller.nativeObjectID != targetIDs[proxmoxObjectKindNode] ||
			!proxmoxConsoleSourceFieldsMatch(targetIDs, controller) {
			return errPluginHostAuthorityMalformed
		}
	default:
		return errPluginHostAuthorityMalformed
	}

	if cluster := targetIDs[proxmoxObjectKindCluster]; cluster != "" && cluster != targetIDs["native_cluster_id"] {
		return errPluginHostAuthorityMalformed
	}

	return nil
}

func proxmoxConsoleSourceFieldsMatch(
	targetIDs map[string]string,
	identity proxmoxConsoleTargetIdentity,
) bool {
	return identity.integrationID == targetIDs["integration_id"] &&
		identity.controllerID == targetIDs["controller_id"] &&
		identity.providerInstanceRef == targetIDs["provider_instance_ref"] &&
		identity.nativeClusterID == targetIDs["native_cluster_id"]
}

func proxmoxPolicyIDMatches(policyID, ruleID, pluginID, entrypoint string) bool {
	prefix := "network-credential-rule:" + ruleID
	switch {
	case pluginID == proxmoxInventoryPluginID && entrypoint == proxmoxInventoryEntrypoint:
		// The materializer preserves unsuffixed inventory policy IDs. Match both
		// exact forms, as the core host-authority validator does.
		return policyID == prefix || policyID == prefix+":"+proxmoxInventoryPurpose
	case pluginID == proxmoxConsolePluginID && entrypoint == proxmoxConsoleEntrypoint:
		return policyID == prefix+":"+proxmoxConsolePurpose
	default:
		return false
	}
}

func validateProxmoxPublicParams(
	raw []byte,
	assignmentID string,
	pluginID string,
	entrypoint string,
) (proxmoxAssignmentPolicyBinding, error) {
	var root any
	if err := decodeStrictJSON(raw, &root); err != nil {
		return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
	}
	rootMap, ok := root.(map[string]any)
	if !ok {
		return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
	}
	policyID, ok := rootMap["policy_id"].(string)
	if !ok || !validPluginHostAuthorityString(policyID) {
		return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
	}
	policyVersion, ok := strictPositiveJSONUint64(rootMap["policy_version"])
	if !ok {
		return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
	}

	ruleIDs := make(map[string]struct{})
	sentinelCount := 0
	var walk func(any) error
	walk = func(value any) error {
		switch typed := value.(type) {
		case map[string]any:
			if schema, _ := typed["schema"].(string); schema == pluginHostAuthoritySchema {
				return errPluginHostAuthorityMalformed
			}
			for key, child := range typed {
				switch key {
				case "_serviceradar_host_authority", "host_authority", "host_params", "host_params_json",
					"credential_broker", "api_token_secret_ref", "credential_secret_ref",
					"password_secret_ref", "api_key_secret_ref", "_secret_material",
					"private_key", credentialFormFieldPassword, "passphrase", "known_hosts_path", "ssh",
					"ssh_host_key_policy":
					return errPluginHostAuthorityMalformed
				case "api_token", "credential_secret":
					text, ok := child.(string)
					if !ok || text != pluginHostCredentialSentinel {
						return errPluginHostAuthorityMalformed
					}
					sentinelCount++
					continue
				case "credential_rule_id":
					text, ok := child.(string)
					if !ok || !validPluginHostAuthorityString(text) {
						return errPluginHostAuthorityMalformed
					}
					ruleIDs[text] = struct{}{}
				}
				if err := walk(child); err != nil {
					return err
				}
			}
		case []any:
			for _, child := range typed {
				if err := walk(child); err != nil {
					return err
				}
			}
		}
		return nil
	}

	if err := walk(root); err != nil || sentinelCount == 0 || len(ruleIDs) != 1 {
		return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
	}
	for ruleID := range ruleIDs {
		if !proxmoxPolicyIDMatches(policyID, ruleID, pluginID, entrypoint) || !validPluginHostAuthorityString(assignmentID) {
			return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
		}

		fingerprint := proxmoxAssignmentPolicyFingerprint(
			assignmentID,
			pluginID,
			entrypoint,
			policyID,
			policyVersion,
			ruleID,
		)
		return proxmoxAssignmentPolicyBinding{
			PolicyID:         policyID,
			PolicyVersion:    policyVersion,
			CredentialRuleID: ruleID,
			Fingerprint:      fingerprint,
		}, nil
	}
	return proxmoxAssignmentPolicyBinding{}, errPluginHostAuthorityMalformed
}

func strictPositiveJSONUint64(value any) (uint64, bool) {
	number, ok := value.(json.Number)
	if !ok || strings.ContainsAny(number.String(), ".eE+-") {
		return 0, false
	}
	parsed, err := strconv.ParseUint(number.String(), 10, 64)
	return parsed, err == nil && parsed > 0
}

func proxmoxAssignmentPolicyFingerprint(
	assignmentID string,
	pluginID string,
	entrypoint string,
	policyID string,
	policyVersion uint64,
	credentialRuleID string,
) string {
	canonical := strings.Join([]string{
		proxmoxAssignmentPolicyDomain,
		assignmentID,
		pluginID,
		entrypoint,
		policyID,
		strconv.FormatUint(policyVersion, 10),
		credentialRuleID,
	}, "\n")
	sum := sha256.Sum256([]byte(canonical))
	return hex.EncodeToString(sum[:])
}

func validProxmoxAssignmentPolicyFingerprint(value string) bool {
	if len(value) != sha256.Size*2 || strings.ToLower(value) != value {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func validProxmoxSSHHostKeyPolicy(value string) bool {
	switch value {
	case "", proxmoxSSHHostKeyPolicyKnownHosts, proxmoxSSHHostKeyPolicyTrustFirstUse:
		return true
	default:
		return false
	}
}

func validProxmoxSSHHostBindingPolicy(
	pluginID string,
	policy string,
	grant credentialBrokerGrant,
) bool {
	sshGrant := pluginID == proxmoxConsolePluginID &&
		len(grant.Allow.Methods) == 0 && len(grant.Allow.Paths) == 0 &&
		len(grant.Allow.Ports) == 1 && grant.Allow.Ports[0] == 22

	if sshGrant {
		return policy == proxmoxSSHHostKeyPolicyKnownHosts ||
			policy == proxmoxSSHHostKeyPolicyTrustFirstUse
	}
	return policy == ""
}

func validPluginHostAuthorityString(value string) bool {
	if value == "" || len(value) > maximumPluginHostAuthorityStringBytes || strings.TrimSpace(value) != value {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func canonicalPluginHostAuthorityOrigin(raw string) (origin, scheme string, err error) {
	parsed, parseErr := url.Parse(raw)
	if parseErr != nil || parsed == nil || parsed.Opaque != "" || parsed.Host == "" || parsed.User != nil ||
		parsed.Path != "" || parsed.RawPath != "" || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" {
		return "", "", errPluginHostAuthorityMalformed
	}

	scheme = strings.ToLower(parsed.Scheme)
	if scheme != httpScheme && scheme != httpsScheme {
		return "", "", errPluginHostAuthorityMalformed
	}
	host := strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
	if host == "" || strings.Contains(host, "%") {
		return "", "", errPluginHostAuthorityMalformed
	}
	port, ok := pluginHTTPRequestPort(parsed)
	if !ok {
		return "", "", errPluginHostAuthorityMalformed
	}
	return scheme + "://" + net.JoinHostPort(host, strconv.Itoa(port)), scheme, nil
}

func canonicalPluginHostAuthorityRequestOrigin(requestURL *url.URL) (string, error) {
	if requestURL == nil || requestURL.Opaque != "" || requestURL.Host == "" || requestURL.User != nil ||
		requestURL.Fragment != "" {
		return "", errPluginHostAuthorityDenied
	}
	scheme := strings.ToLower(requestURL.Scheme)
	if scheme != httpScheme && scheme != httpsScheme {
		return "", errPluginHostAuthorityDenied
	}
	host := strings.ToLower(strings.TrimSuffix(requestURL.Hostname(), "."))
	if host == "" || strings.Contains(host, "%") {
		return "", errPluginHostAuthorityDenied
	}
	port, ok := pluginHTTPRequestPort(requestURL)
	if !ok {
		return "", errPluginHostAuthorityDenied
	}
	return scheme + "://" + net.JoinHostPort(host, strconv.Itoa(port)), nil
}

func pluginHostAuthorityBindingScope(binding pluginHostAuthorityBinding) string {
	keys := make([]string, 0, len(binding.targetIDs))
	for key := range binding.targetIDs {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	builder.WriteString(binding.origin)
	builder.WriteByte('\x00')
	builder.WriteString(binding.credentialRuleID)
	for _, key := range keys {
		builder.WriteByte('\x00')
		builder.WriteString(key)
		builder.WriteByte('=')
		builder.WriteString(binding.targetIDs[key])
	}
	return builder.String()
}

func fingerprintPluginHostAuthority(bindings []pluginHostAuthorityBinding) string {
	stable := make([]pluginHostAuthorityStableBinding, 0, len(bindings))
	for _, binding := range bindings {
		grant := cloneCredentialBrokerGrant(binding.credentialBroker)
		// These fields rotate with a lease refresh and are deliberately adopted
		// in place instead of restarting a runner. All stable authority scope,
		// including the secret ref, consumer, inject and allow ACL, remains hashed.
		grant.GrantID = ""
		grant.ExpiresAt = ""
		grant.TTLSeconds = 0
		stable = append(stable, pluginHostAuthorityStableBinding{
			BindingID:                   binding.bindingID,
			Provider:                    binding.provider,
			CredentialRuleID:            binding.credentialRuleID,
			Origin:                      binding.origin,
			InsecureSkipVerify:          binding.insecureSkipVerify,
			AssignmentPolicyVersion:     binding.assignmentPolicyVersion,
			AssignmentPolicyFingerprint: binding.assignmentPolicyFingerprint,
			SSHHostKeyPolicy:            binding.sshHostKeyPolicy,
			CABundlePEM:                 binding.caBundlePEM,
			ServerCertFingerprint:       binding.serverCertFingerprint,
			CredentialBroker:            grant,
			TargetIDs:                   cloneHostAuthorityStringMap(binding.targetIDs),
		})
	}
	sort.Slice(stable, func(i, j int) bool { return stable[i].BindingID < stable[j].BindingID })
	encoded, err := json.Marshal(stable)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:])
}

func fingerprintPluginHostAuthorityInputs(paramsJSON, hostParamsJSON []byte) string {
	hash := sha256.New()
	writeAWXFingerprintBytes(hash, paramsJSON)
	writeAWXFingerprintBytes(hash, hostParamsJSON)
	return hex.EncodeToString(hash.Sum(nil))
}

func (a *pluginAssignment) replacePluginHostAuthority(bindings []pluginHostAuthorityBinding, fingerprint string) {
	if a == nil {
		return
	}
	a.hostAuthorityMu.Lock()
	defer a.hostAuthorityMu.Unlock()
	a.pluginHostAuthority = clonePluginHostAuthorityBindings(bindings)
	a.pluginHostAuthorityFingerprint = fingerprint
}

func (a *pluginAssignment) pluginHostAuthoritySnapshot() ([]pluginHostAuthorityBinding, string) {
	if a == nil {
		return nil, ""
	}
	a.hostAuthorityMu.RLock()
	defer a.hostAuthorityMu.RUnlock()
	return clonePluginHostAuthorityBindings(a.pluginHostAuthority), a.pluginHostAuthorityFingerprint
}

func (a *pluginAssignment) proxmoxAssignmentPolicyBinding() (proxmoxAssignmentPolicyBinding, bool) {
	bindings, _ := a.pluginHostAuthoritySnapshot()
	if len(bindings) == 0 {
		return proxmoxAssignmentPolicyBinding{}, false
	}

	first := bindings[0]
	policy := proxmoxAssignmentPolicyBinding{
		PolicyVersion:    first.assignmentPolicyVersion,
		CredentialRuleID: first.credentialRuleID,
		Fingerprint:      first.assignmentPolicyFingerprint,
	}
	if policy.PolicyVersion == 0 || !validProxmoxAssignmentPolicyFingerprint(policy.Fingerprint) {
		return proxmoxAssignmentPolicyBinding{}, false
	}
	for _, binding := range bindings[1:] {
		if binding.assignmentPolicyVersion != policy.PolicyVersion ||
			binding.assignmentPolicyFingerprint != policy.Fingerprint ||
			binding.credentialRuleID != policy.CredentialRuleID {
			return proxmoxAssignmentPolicyBinding{}, false
		}
	}
	return policy, true
}

func (a *pluginAssignment) refreshPluginHostAuthority(fresh *pluginAssignment) {
	if a == nil || fresh == nil || !a.proxmoxHostAuthorityRequired || !fresh.proxmoxHostAuthorityRequired {
		return
	}
	bindings, fingerprint := fresh.pluginHostAuthoritySnapshot()
	_, currentFingerprint := a.pluginHostAuthoritySnapshot()
	if fingerprint == "" || fingerprint != currentFingerprint {
		return
	}
	a.replacePluginHostAuthority(bindings, fingerprint)
}

func clonePluginHostAuthorityBindings(bindings []pluginHostAuthorityBinding) []pluginHostAuthorityBinding {
	if len(bindings) == 0 {
		return nil
	}
	out := make([]pluginHostAuthorityBinding, 0, len(bindings))
	for _, binding := range bindings {
		binding.credentialBroker = cloneCredentialBrokerGrant(binding.credentialBroker)
		binding.targetIDs = cloneHostAuthorityStringMap(binding.targetIDs)
		out = append(out, binding)
	}
	return out
}

func cloneCredentialBrokerGrant(grant credentialBrokerGrant) credentialBrokerGrant {
	grant.Consumer = cloneHostAuthorityStringMap(grant.Consumer)
	grant.Inject = cloneHostAuthorityStringMap(grant.Inject)
	grant.Allow.Methods = append([]string(nil), grant.Allow.Methods...)
	grant.Allow.Paths = append([]string(nil), grant.Allow.Paths...)
	grant.Allow.Hosts = append([]string(nil), grant.Allow.Hosts...)
	grant.Allow.Ports = append([]int(nil), grant.Allow.Ports...)
	return grant
}

func cloneHostAuthorityStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	out := make(map[string]string, len(values))
	for key, value := range values {
		out[key] = value
	}
	return out
}

func decodeStrictJSON(raw []byte, destination any) error {
	if len(raw) == 0 || len(raw) > pluginMaxPayloadBytes {
		return errPluginHostAuthorityMalformed
	}
	if err := rejectDuplicateJSONFields(raw); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errPluginHostAuthorityMalformed
	}
	return nil
}

func rejectDuplicateJSONFields(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := consumeUniqueJSONValue(decoder); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errPluginHostAuthorityMalformed
	}
	return nil
}

func consumeUniqueJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}

	switch delim {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errPluginHostAuthorityMalformed
			}
			if _, duplicate := seen[key]; duplicate {
				return errPluginHostAuthorityMalformed
			}
			seen[key] = struct{}{}
			if err := consumeUniqueJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim('}') {
			return errPluginHostAuthorityMalformed
		}
	case '[':
		for decoder.More() {
			if err := consumeUniqueJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim(']') {
			return errPluginHostAuthorityMalformed
		}
	default:
		return errPluginHostAuthorityMalformed
	}
	return nil
}

func pluginHostAuthorityGrantRequestAllowed(grant credentialBrokerGrant, method string, requestURL *url.URL) bool {
	if requestURL == nil || requestURL.Host == "" {
		return false
	}
	if len(grant.Allow.Methods) > 0 && !stringInFoldedList(method, grant.Allow.Methods) {
		return false
	}
	path := requestURL.EscapedPath()
	if path == "" {
		path = "/"
	}
	if len(grant.Allow.Paths) > 0 && !credentialBrokerPathAllowed(grant.Allow.Paths, path) {
		return false
	}
	if len(grant.Allow.Hosts) > 0 &&
		!stringInFoldedList(requestURL.Hostname(), grant.Allow.Hosts) &&
		!stringInFoldedList(requestURL.Host, grant.Allow.Hosts) {
		return false
	}
	if len(grant.Allow.Ports) > 0 {
		port, ok := pluginHTTPRequestPort(requestURL)
		if !ok || !intInList(port, grant.Allow.Ports) {
			return false
		}
	}
	return true
}

func safeCredentialRequestPath(requestURL *url.URL) bool {
	if requestURL == nil || requestURL.RawPath != "" || strings.ContainsAny(requestURL.Path, "\\%") {
		return false
	}
	for _, segment := range strings.Split(requestURL.Path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

func proxmoxInventoryHostAuthorityRequestAllowed(method string, requestURL *url.URL, body []byte) bool {
	if method != http.MethodGet || len(body) != 0 || !safeCredentialRequestPath(requestURL) ||
		requestURL.RawQuery != "" || requestURL.ForceQuery {
		return false
	}

	segments := strings.Split(strings.TrimPrefix(requestURL.Path, "/"), "/")
	return proxmoxInventoryPathAllowed(segments)
}

func proxmoxInventoryPathAllowed(segments []string) bool {
	if len(segments) < 3 || segments[0] != "api2" || segments[1] != "json" {
		return false
	}
	if len(segments) == 3 && (segments[2] == "version" || segments[2] == "nodes") {
		return true
	}
	if len(segments) == 4 && segments[2] == proxmoxObjectKindCluster &&
		(segments[3] == proxmoxAPIStatusSegment || segments[3] == "resources") {
		return true
	}
	if len(segments) < 5 || segments[2] != "nodes" || !validProxmoxInventoryPathSegment(segments[3]) {
		return false
	}

	switch {
	case len(segments) == 5:
		return proxmoxInventoryNodeCollectionAllowed(segments[4])
	case len(segments) == 6:
		return segments[4] == "disks" && segments[5] == "list" ||
			segments[4] == "ceph" && segments[5] == proxmoxAPIStatusSegment
	case len(segments) == 7 &&
		(segments[4] == proxmoxObjectKindQEMU || segments[4] == proxmoxObjectKindLXC):
		_, validVMID := parseStrictPositiveInt(segments[5])
		return validVMID &&
			(segments[6] == "config" || segments[4] == proxmoxObjectKindLXC && segments[6] == "interfaces")
	case len(segments) == 8 && segments[4] == proxmoxObjectKindQEMU &&
		segments[6] == proxmoxAPIAgentSegment:
		_, validVMID := parseStrictPositiveInt(segments[5])
		return validVMID && (segments[7] == "network-get-interfaces" || segments[7] == "get-fsinfo")
	}

	return false
}

func proxmoxInventoryNodeCollectionAllowed(resource string) bool {
	switch resource {
	case proxmoxAPIStatusSegment, "storage", "network", proxmoxObjectKindQEMU, proxmoxObjectKindLXC:
		return true
	default:
		return false
	}
}

func validProxmoxInventoryPathSegment(value string) bool {
	return value != "" && value != "." && value != ".." && validPluginHostAuthorityString(value)
}

func proxmoxAuthorizationValue(material CredentialBrokerMaterial) (string, error) {
	value := credentialMaterialValue(material, "api_token", "token", "value", "Authorization")
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "PVEAPIToken=")
	if value == "" || len(value) > 64*1024 || strings.TrimSpace(value) != value {
		return "", errPluginHostAuthorityDenied
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return "", errPluginHostAuthorityDenied
		}
	}
	return "PVEAPIToken=" + value, nil
}

func (e *pluginExecution) proxmoxHostAuthorityForHTTPRequest(
	method string,
	requestURL *url.URL,
	body []byte,
	insecureSkipVerify bool,
) (*pluginHostAuthorityBinding, error) {
	if e == nil || e.assignment == nil || !e.assignment.proxmoxHostAuthorityRequired {
		return nil, nil
	}
	if err := e.ensureActiveProxmoxAssignment(context.Background()); err != nil {
		return nil, err
	}
	if e.mode != pluginExecutionModeScheduled && e.mode != pluginExecutionModeStreaming {
		return nil, errPluginHostAuthorityDenied
	}
	if requestURL == nil || !strings.EqualFold(requestURL.Scheme, httpsScheme) {
		return nil, errPluginHostAuthorityDenied
	}

	origin, err := canonicalPluginHostAuthorityRequestOrigin(requestURL)
	if err != nil {
		return nil, errPluginHostAuthorityDenied
	}
	binding, err := e.selectProxmoxHostAuthorityBinding(origin)
	if err != nil || binding.insecureSkipVerify != insecureSkipVerify {
		return nil, errPluginHostAuthorityDenied
	}

	switch e.assignment.PluginID {
	case proxmoxInventoryPluginID:
		if !proxmoxInventoryHostAuthorityRequestAllowed(method, requestURL, body) {
			return nil, formatPluginHostAuthorityError(binding)
		}
	case proxmoxConsolePluginID:
		proxyPath, _, pathErr := expectedProxmoxConsolePaths(e.consoleSessionSpec, binding)
		if pathErr != nil || method != http.MethodPost || len(body) != 0 || !safeCredentialRequestPath(requestURL) ||
			requestURL.Path != proxyPath {
			return nil, formatPluginHostAuthorityError(binding)
		}
	default:
		return nil, errPluginHostAuthorityDenied
	}

	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}
	if validatePluginActionCredentialGrantEnvelope(binding.credentialBroker, now) != nil ||
		!pluginHostAuthorityGrantRequestAllowed(binding.credentialBroker, method, requestURL) {
		return nil, formatPluginHostAuthorityError(binding)
	}
	return &binding, nil
}

func (e *pluginExecution) selectProxmoxHostAuthorityBinding(origin string) (pluginHostAuthorityBinding, error) {
	bindings, _ := e.assignment.pluginHostAuthoritySnapshot()
	if len(bindings) == 0 {
		return pluginHostAuthorityBinding{}, errPluginHostAuthorityDenied
	}

	ruleID := ""
	if e.assignment.PluginID == proxmoxConsolePluginID {
		ruleID = strings.TrimSpace(e.consoleSessionSpec.CredentialRuleID)
	}
	if ruleID == "" {
		ruleID = e.assignment.proxmoxHostAuthorityCredentialRuleID()
	}

	candidates := make([]pluginHostAuthorityBinding, 0, len(bindings))
	for _, binding := range bindings {
		if binding.origin != origin || binding.credentialRuleID != ruleID {
			continue
		}
		if e.assignment.PluginID == proxmoxConsolePluginID && !pluginHostAuthorityBindingMatchesConsole(binding, e.consoleSessionSpec) {
			continue
		}
		candidates = append(candidates, binding)
	}
	if len(candidates) == 0 {
		return pluginHostAuthorityBinding{}, errPluginHostAuthorityDenied
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].bindingID < candidates[j].bindingID })
	selected := candidates[0]
	for _, candidate := range candidates[1:] {
		if candidate.insecureSkipVerify != selected.insecureSkipVerify ||
			candidate.credentialBroker.CredentialSecretRef != selected.credentialBroker.CredentialSecretRef ||
			candidate.credentialBroker.Consumer["purpose"] != selected.credentialBroker.Consumer["purpose"] {
			return pluginHostAuthorityBinding{}, errPluginHostAuthorityDenied
		}
	}
	return selected, nil
}

func (a *pluginAssignment) proxmoxHostAuthorityCredentialRuleID() string {
	bindings, _ := a.pluginHostAuthoritySnapshot()
	ruleID := ""
	for _, binding := range bindings {
		if ruleID == "" {
			ruleID = binding.credentialRuleID
			continue
		}
		if binding.credentialRuleID != ruleID {
			return ""
		}
	}
	return ruleID
}

func pluginHostAuthorityDestinationAllowed(
	permissions *pluginPermissions,
	requestURL *url.URL,
	binding *pluginHostAuthorityBinding,
) bool {
	if permissions == nil || requestURL == nil || binding == nil {
		return false
	}
	port, ok := pluginHTTPRequestPort(requestURL)
	if !ok || !permissions.allowsHTTPPort(port) {
		return false
	}
	origin, err := canonicalPluginHostAuthorityRequestOrigin(requestURL)
	return err == nil && origin == binding.origin
}

func (e *pluginExecution) applyProxmoxHostAuthorityCredential(
	ctx context.Context,
	request *http.Request,
	binding *pluginHostAuthorityBinding,
) error {
	if binding == nil {
		return nil
	}
	if request == nil || request.Header.Get("Authorization") != pluginHostCredentialSentinel ||
		e == nil || e.manager == nil {
		return errPluginHostAuthorityDenied
	}
	if err := e.ensureActiveProxmoxAssignment(ctx); err != nil {
		return err
	}
	material, err := e.manager.resolveCredentialBrokerMaterial(ctx, binding.credentialBroker)
	if err != nil {
		return err
	}
	value, err := proxmoxAuthorizationValue(material)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", value)
	return nil
}

type proxmoxConsoleTargetIdentity struct {
	cluster             string
	node                string
	kind                string
	vmid                int
	integrationID       string
	controllerID        string
	providerInstanceRef string
	nativeClusterID     string
	objectKind          string
	nativeObjectID      string
}

func parseAgentProxmoxProviderRef(raw string) (proxmoxConsoleTargetIdentity, bool) {
	parts := strings.Split(strings.TrimSpace(raw), ":")
	if len(parts) < 3 || parts[0] != proxmoxProviderName {
		return proxmoxConsoleTargetIdentity{}, false
	}

	switch parts[1] {
	case "v3":
		return parseAgentProxmoxProviderRefV3(parts)
	case "v2":
		return parseAgentProxmoxProviderRefV2(parts)
	case proxmoxObjectKindNode:
		return parseAgentProxmoxLegacyNodeRef(parts)
	case "guest":
		return parseAgentProxmoxLegacyGuestRef(parts)
	case proxmoxObjectKindCluster:
		return parseAgentProxmoxLegacyClusterRef(parts)
	default:
		return proxmoxConsoleTargetIdentity{}, false
	}
}

func parseAgentProxmoxProviderRefV3(parts []string) (proxmoxConsoleTargetIdentity, bool) {
	if len(parts) != 7 {
		return proxmoxConsoleTargetIdentity{}, false
	}
	instance, ok := parseAgentProxmoxProviderInstanceRef(strings.Join(parts[:5], ":"))
	nativeID, nativeIDOK := decodeCanonicalProxmoxV3NativeComponent(parts[6])
	kind := parts[5]
	if !ok || !nativeIDOK {
		return proxmoxConsoleTargetIdentity{}, false
	}

	switch kind {
	case proxmoxObjectKindNode:
		return proxmoxConsoleTargetIdentity{
			cluster:             instance.nativeClusterID,
			node:                nativeID,
			kind:                proxmoxTargetKindPVEHost,
			integrationID:       instance.integrationID,
			controllerID:        instance.controllerID,
			providerInstanceRef: instance.providerInstanceRef,
			nativeClusterID:     instance.nativeClusterID,
			objectKind:          kind,
			nativeObjectID:      nativeID,
		}, true
	case proxmoxObjectKindQEMU, proxmoxObjectKindLXC:
		vmid, validVMID := parseStrictPositiveInt(nativeID)
		if !validVMID {
			return proxmoxConsoleTargetIdentity{}, false
		}
		return proxmoxConsoleTargetIdentity{
			cluster:             instance.nativeClusterID,
			kind:                proxmoxTargetKind(kind),
			vmid:                vmid,
			integrationID:       instance.integrationID,
			controllerID:        instance.controllerID,
			providerInstanceRef: instance.providerInstanceRef,
			nativeClusterID:     instance.nativeClusterID,
			objectKind:          kind,
			nativeObjectID:      nativeID,
		}, true
	default:
		return proxmoxConsoleTargetIdentity{}, false
	}
}

func parseAgentProxmoxProviderRefV2(parts []string) (proxmoxConsoleTargetIdentity, bool) {
	if len(parts) != 5 || parts[2] == "" {
		return proxmoxConsoleTargetIdentity{}, false
	}
	cluster, clusterErr := url.PathUnescape(parts[2])
	nativeID, nativeIDErr := url.PathUnescape(parts[4])
	kind := strings.ToLower(parts[3])
	if clusterErr != nil || nativeIDErr != nil || !validPluginHostAuthorityString(cluster) ||
		!validPluginHostAuthorityString(nativeID) {
		return proxmoxConsoleTargetIdentity{}, false
	}

	switch kind {
	case proxmoxObjectKindNode:
		return proxmoxConsoleTargetIdentity{
			cluster:         cluster,
			node:            nativeID,
			kind:            proxmoxTargetKindPVEHost,
			nativeClusterID: cluster,
			objectKind:      kind,
			nativeObjectID:  nativeID,
		}, true
	case "vm", proxmoxObjectKindQEMU, proxmoxObjectKindLXC:
		vmid, validVMID := parseStrictPositiveInt(nativeID)
		if !validVMID {
			return proxmoxConsoleTargetIdentity{}, false
		}
		return proxmoxConsoleTargetIdentity{
			cluster:         cluster,
			kind:            proxmoxTargetKind(kind),
			vmid:            vmid,
			nativeClusterID: cluster,
			objectKind:      kind,
			nativeObjectID:  nativeID,
		}, true
	default:
		return proxmoxConsoleTargetIdentity{}, false
	}
}

func parseAgentProxmoxLegacyNodeRef(parts []string) (proxmoxConsoleTargetIdentity, bool) {
	if len(parts) != 3 || parts[2] == "" {
		return proxmoxConsoleTargetIdentity{}, false
	}
	return proxmoxConsoleTargetIdentity{
		node:           parts[2],
		kind:           proxmoxTargetKindPVEHost,
		objectKind:     proxmoxObjectKindNode,
		nativeObjectID: parts[2],
	}, true
}

func parseAgentProxmoxLegacyGuestRef(parts []string) (proxmoxConsoleTargetIdentity, bool) {
	if len(parts) != 5 || parts[2] == "" {
		return proxmoxConsoleTargetIdentity{}, false
	}
	vmid, ok := parseStrictPositiveInt(parts[4])
	if !ok {
		return proxmoxConsoleTargetIdentity{}, false
	}
	return proxmoxConsoleTargetIdentity{
		node:           parts[2],
		kind:           proxmoxTargetKind(parts[3]),
		vmid:           vmid,
		objectKind:     strings.ToLower(parts[3]),
		nativeObjectID: parts[4],
	}, true
}

func parseAgentProxmoxLegacyClusterRef(parts []string) (proxmoxConsoleTargetIdentity, bool) {
	if len(parts) < 5 || parts[2] == "" {
		return proxmoxConsoleTargetIdentity{}, false
	}
	if parts[3] == proxmoxObjectKindNode && len(parts) == 5 && parts[4] != "" {
		return proxmoxConsoleTargetIdentity{
			cluster:         parts[2],
			node:            parts[4],
			kind:            proxmoxTargetKindPVEHost,
			nativeClusterID: parts[2],
			objectKind:      proxmoxObjectKindNode,
			nativeObjectID:  parts[4],
		}, true
	}
	if parts[3] != "guest" || len(parts) != 7 || parts[4] == "" {
		return proxmoxConsoleTargetIdentity{}, false
	}
	vmid, ok := parseStrictPositiveInt(parts[6])
	if !ok {
		return proxmoxConsoleTargetIdentity{}, false
	}
	return proxmoxConsoleTargetIdentity{
		cluster:         parts[2],
		node:            parts[4],
		kind:            proxmoxTargetKind(parts[5]),
		vmid:            vmid,
		nativeClusterID: parts[2],
		objectKind:      strings.ToLower(parts[5]),
		nativeObjectID:  parts[6],
	}, true
}

func parseAgentProxmoxProviderInstanceRef(raw string) (proxmoxConsoleTargetIdentity, bool) {
	trimmed := strings.TrimSpace(raw)
	parts := strings.Split(trimmed, ":")
	if len(parts) != 5 || parts[0] != proxmoxProviderName || parts[1] != "v3" ||
		!isCanonicalPluginUUID(parts[2]) || !isCanonicalPluginUUID(parts[3]) {
		return proxmoxConsoleTargetIdentity{}, false
	}
	cluster, ok := decodeCanonicalProxmoxV3NativeComponent(parts[4])
	if !ok {
		return proxmoxConsoleTargetIdentity{}, false
	}
	return proxmoxConsoleTargetIdentity{
		cluster:             cluster,
		integrationID:       parts[2],
		controllerID:        parts[3],
		providerInstanceRef: trimmed,
		nativeClusterID:     cluster,
	}, true
}

func decodeCanonicalProxmoxV3NativeComponent(encoded string) (string, bool) {
	decoded, err := url.PathUnescape(encoded)
	if err != nil || !utf8.ValidString(decoded) || decoded == "" || decoded != strings.TrimSpace(decoded) ||
		!validPluginHostAuthorityString(decoded) || encodeProxmoxV3NativeComponent(decoded) != encoded {
		return "", false
	}
	return decoded, true
}

func encodeProxmoxV3NativeComponent(value string) string {
	const upperHex = "0123456789ABCDEF"

	var encoded strings.Builder
	encoded.Grow(len(value))
	for i := 0; i < len(value); i++ {
		current := value[i]
		if current >= 'a' && current <= 'z' || current >= 'A' && current <= 'Z' ||
			current >= '0' && current <= '9' || current == '-' || current == '.' || current == '_' || current == '~' {
			encoded.WriteByte(current)
			continue
		}
		encoded.WriteByte('%')
		encoded.WriteByte(upperHex[current>>4])
		encoded.WriteByte(upperHex[current&0x0f])
	}
	return encoded.String()
}

func isCanonicalPluginUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i := 0; i < len(value); i++ {
		switch i {
		case 8, 13, 18, 23:
			if value[i] != '-' {
				return false
			}
		default:
			if (value[i] < '0' || value[i] > '9') && (value[i] < 'a' || value[i] > 'f') {
				return false
			}
		}
	}
	return true
}

func proxmoxTargetKind(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case proxmoxObjectKindQEMU, "vm", proxmoxTargetKindQEMUGuest:
		return proxmoxTargetKindQEMUGuest
	case proxmoxObjectKindLXC, "container", proxmoxTargetKindLXCGuest:
		return proxmoxTargetKindLXCGuest
	case proxmoxObjectKindNode, "host", proxmoxTargetKindPVEHost:
		return proxmoxTargetKindPVEHost
	default:
		return ""
	}
}

func pluginHostAuthorityBindingMatchesConsole(binding pluginHostAuthorityBinding, spec proxmoxConsoleSessionSpec) bool {
	if strings.TrimSpace(spec.CredentialRuleID) == "" || binding.credentialRuleID != strings.TrimSpace(spec.CredentialRuleID) {
		return false
	}
	if !consoleSpecOriginMatchesBinding(spec, binding) {
		return false
	}

	identity, valid := consoleSpecAuthorityIdentityFromSession(spec)
	if !valid {
		return false
	}
	return pluginHostAuthorityTargetIDsMatchConsole(binding.targetIDs, identity)
}

type consoleSpecAuthorityIdentity struct {
	subject    map[string]string
	controller map[string]string
}

func pluginHostAuthorityTargetIDsMatchConsole(
	targetIDs map[string]string,
	identity consoleSpecAuthorityIdentity,
) bool {
	// Controller-scoped bindings carry object_kind=node. Subject-specific
	// bindings carry qemu/lxc identity plus explicit controller_* fields.
	// Node/cluster/source IDs always describe the owning PVE controller; guest
	// vmid/kind/object identity always describes the console subject.
	objectKind := strings.ToLower(strings.TrimSpace(targetIDs["object_kind"]))
	controllerScoped := objectKind == proxmoxObjectKindNode
	for key, expected := range targetIDs {
		var actual string
		switch key {
		case proxmoxObjectKindNode, proxmoxObjectKindCluster, "controller_id", "provider_instance_ref", "native_cluster_id":
			actual = identity.controller[key]
		case "controller_device_uid":
			actual = identity.controller["device_uid"]
		case "controller_provider_ref":
			actual = identity.controller["provider_ref"]
		case "vmid", "target_kind":
			actual = identity.subject[key]
		case "device_uid", "integration_id", "provider_ref", "object_kind", "native_object_id":
			if controllerScoped {
				actual = identity.controller[key]
			} else {
				actual = identity.subject[key]
			}
		default:
			return false
		}
		present := actual != ""
		if !present || actual == "" || actual != expected {
			return false
		}
	}
	return true
}

type consoleSpecAuthorityState struct {
	deviceUID                string
	providerRef              string
	controllerDeviceUID      string
	controllerRef            string
	targetKind               string
	node                     string
	cluster                  string
	vmid                     int
	integrationID            string
	controllerID             string
	providerInstanceRef      string
	nativeClusterID          string
	objectKind               string
	nativeObjectID           string
	controllerObjectKind     string
	controllerNativeObjectID string
}

func consoleSpecAuthorityIdentityFromSession(spec proxmoxConsoleSessionSpec) (consoleSpecAuthorityIdentity, bool) {
	state, ok := newConsoleSpecAuthorityState(spec)
	if !ok || !state.mergeSubjectProviderRef() || !state.mergeControllerProviderRef() {
		return consoleSpecAuthorityIdentity{}, false
	}
	return state.identity(), true
}

func newConsoleSpecAuthorityState(spec proxmoxConsoleSessionSpec) (consoleSpecAuthorityState, bool) {
	deviceUID := strings.TrimSpace(spec.DeviceUID)
	if targetDeviceUID := strings.TrimSpace(spec.Target.DeviceUID); targetDeviceUID != "" {
		if deviceUID != "" && deviceUID != targetDeviceUID {
			return consoleSpecAuthorityState{}, false
		}
		deviceUID = targetDeviceUID
	}

	providerRef := strings.TrimSpace(spec.Target.ProviderRef)
	targetRef := strings.TrimSpace(spec.Target.TargetRef)
	if providerRef != "" && targetRef != "" && providerRef != targetRef {
		return consoleSpecAuthorityState{}, false
	}
	providerRef = firstNonEmpty(providerRef, targetRef)
	controllerDeviceUID := strings.TrimSpace(spec.Target.ControllerDeviceUID)
	controllerRef := strings.TrimSpace(spec.Target.ControllerRef)
	if deviceUID == "" || providerRef == "" || controllerDeviceUID == "" || controllerRef == "" {
		return consoleSpecAuthorityState{}, false
	}

	targetKind := proxmoxTargetKind(spec.TargetKind)
	if targetKindFromTarget := proxmoxTargetKind(spec.Target.TargetKind); targetKindFromTarget != "" {
		if targetKind != "" && targetKind != targetKindFromTarget {
			return consoleSpecAuthorityState{}, false
		}
		targetKind = targetKindFromTarget
	}

	node := strings.TrimSpace(spec.Target.Node)
	ownerNode := strings.TrimSpace(spec.Target.OwnerNode)
	if node != "" && ownerNode != "" && node != ownerNode {
		return consoleSpecAuthorityState{}, false
	}
	node = firstNonEmpty(node, ownerNode)
	integrationID := strings.TrimSpace(spec.Target.IntegrationID)
	controllerIntegrationID := strings.TrimSpace(spec.Target.ControllerIntegrationID)
	controllerID := strings.TrimSpace(spec.Target.ControllerID)
	providerInstanceRef := strings.TrimSpace(spec.Target.ProviderInstanceRef)
	nativeClusterID := strings.TrimSpace(spec.Target.NativeClusterID)
	if integrationID == "" || controllerIntegrationID == "" || integrationID != controllerIntegrationID ||
		spec.Target.VMID < 0 || controllerID == "" || providerInstanceRef == "" || nativeClusterID == "" {
		return consoleSpecAuthorityState{}, false
	}

	return consoleSpecAuthorityState{
		deviceUID:           deviceUID,
		providerRef:         providerRef,
		controllerDeviceUID: controllerDeviceUID,
		controllerRef:       controllerRef,
		targetKind:          targetKind,
		node:                node,
		cluster:             strings.TrimSpace(spec.Target.Cluster),
		vmid:                spec.Target.VMID,
		integrationID:       integrationID,
		controllerID:        controllerID,
		providerInstanceRef: providerInstanceRef,
		nativeClusterID:     nativeClusterID,
		objectKind:          strings.ToLower(strings.TrimSpace(spec.Target.ObjectKind)),
		nativeObjectID:      strings.TrimSpace(spec.Target.NativeObjectID),
	}, true
}

func mergeExactProxmoxIdentityField(current *string, candidate string) bool {
	candidate = strings.TrimSpace(candidate)
	if candidate == "" {
		return true
	}
	if *current != "" && *current != candidate {
		return false
	}
	*current = candidate
	return true
}

func (state *consoleSpecAuthorityState) mergeSubjectProviderRef() bool {
	parsed, ok := parseAgentProxmoxProviderRef(state.providerRef)
	if !ok || parsed.integrationID == "" {
		return false
	}
	if parsed.cluster != "" && !mergeExactProxmoxIdentityField(&state.cluster, parsed.cluster) {
		return false
	}
	if parsed.node != "" && !mergeExactProxmoxIdentityField(&state.node, parsed.node) {
		return false
	}
	if parsed.kind != "" && !mergeExactProxmoxIdentityField(&state.targetKind, parsed.kind) {
		return false
	}
	if parsed.vmid > 0 {
		if state.vmid > 0 && state.vmid != parsed.vmid {
			return false
		}
		state.vmid = parsed.vmid
	}
	return mergeExactProxmoxIdentityField(&state.integrationID, parsed.integrationID) &&
		mergeExactProxmoxIdentityField(&state.controllerID, parsed.controllerID) &&
		mergeExactProxmoxIdentityField(&state.providerInstanceRef, parsed.providerInstanceRef) &&
		mergeExactProxmoxIdentityField(&state.nativeClusterID, parsed.nativeClusterID) &&
		mergeExactProxmoxIdentityField(&state.objectKind, parsed.objectKind) &&
		mergeExactProxmoxIdentityField(&state.nativeObjectID, parsed.nativeObjectID)
}

func (state *consoleSpecAuthorityState) mergeControllerProviderRef() bool {
	parsed, ok := parseAgentProxmoxProviderRef(state.controllerRef)
	if !ok || parsed.integrationID == "" || parsed.objectKind != proxmoxObjectKindNode {
		return false
	}
	if parsed.cluster != "" && !mergeExactProxmoxIdentityField(&state.cluster, parsed.cluster) {
		return false
	}
	if parsed.node != "" && !mergeExactProxmoxIdentityField(&state.node, parsed.node) {
		return false
	}
	return mergeExactProxmoxIdentityField(&state.integrationID, parsed.integrationID) &&
		mergeExactProxmoxIdentityField(&state.controllerID, parsed.controllerID) &&
		mergeExactProxmoxIdentityField(&state.providerInstanceRef, parsed.providerInstanceRef) &&
		mergeExactProxmoxIdentityField(&state.nativeClusterID, parsed.nativeClusterID) &&
		mergeExactProxmoxIdentityField(&state.controllerObjectKind, parsed.objectKind) &&
		mergeExactProxmoxIdentityField(&state.controllerNativeObjectID, parsed.nativeObjectID)
}

func (state consoleSpecAuthorityState) identity() consoleSpecAuthorityIdentity {
	subject := map[string]string{
		"device_uid":            state.deviceUID,
		"integration_id":        state.integrationID,
		"provider_ref":          state.providerRef,
		"target_kind":           state.targetKind,
		"controller_id":         state.controllerID,
		"provider_instance_ref": state.providerInstanceRef,
		"native_cluster_id":     state.nativeClusterID,
		"object_kind":           state.objectKind,
		"native_object_id":      state.nativeObjectID,
	}
	if state.vmid > 0 {
		subject["vmid"] = strconv.Itoa(state.vmid)
	}
	controller := map[string]string{
		"device_uid":             state.controllerDeviceUID,
		"integration_id":         state.integrationID,
		"provider_ref":           state.controllerRef,
		proxmoxObjectKindNode:    state.node,
		proxmoxObjectKindCluster: state.cluster,
		"controller_id":          state.controllerID,
		"provider_instance_ref":  state.providerInstanceRef,
		"native_cluster_id":      state.nativeClusterID,
		"object_kind":            state.controllerObjectKind,
		"native_object_id":       state.controllerNativeObjectID,
	}
	if state.targetKind == proxmoxTargetKindPVEHost {
		// The console subject and controller are the same inventory object for a
		// PVE host. This fallback remains forbidden for guest sessions.
		for _, key := range []string{
			"device_uid", "integration_id", "provider_ref", "object_kind", "native_object_id",
		} {
			if controller[key] == "" {
				controller[key] = subject[key]
			}
		}
	}
	return consoleSpecAuthorityIdentity{subject: subject, controller: controller}
}

func consoleSpecOriginMatchesBinding(spec proxmoxConsoleSessionSpec, binding pluginHostAuthorityBinding) bool {
	origin, err := consoleSpecCanonicalOrigin(spec)
	return err == nil && origin == binding.origin
}

func consoleSpecCanonicalOrigin(spec proxmoxConsoleSessionSpec) (string, error) {
	raw := strings.TrimSpace(spec.Target.BaseURL)
	if raw == "" {
		host := firstNonEmpty(spec.Target.IP, spec.Target.Hostname)
		if host == "" {
			return "", errPluginHostAuthorityDenied
		}
		raw = "https://" + net.JoinHostPort(strings.Trim(host, "[]"), "8006")
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", errPluginHostAuthorityDenied
	}
	return canonicalPluginHostAuthorityRequestOrigin(parsed)
}

func expectedProxmoxConsolePaths(
	spec proxmoxConsoleSessionSpec,
	binding pluginHostAuthorityBinding,
) (proxyPath, websocketPath string, err error) {
	identity, valid := consoleSpecAuthorityIdentityFromSession(spec)
	if !valid || !pluginHostAuthorityTargetIDsMatchConsole(binding.targetIDs, identity) {
		return "", "", errPluginHostAuthorityDenied
	}
	nodeValue := identity.controller[proxmoxObjectKindNode]
	if nodeValue == "" || strings.ContainsAny(nodeValue, "/\\%") {
		return "", "", errPluginHostAuthorityDenied
	}
	node := url.PathEscape(nodeValue)
	kind := proxmoxTargetKind(identity.subject["target_kind"])
	vmid, _ := parseStrictPositiveInt(identity.subject["vmid"])

	switch strings.TrimSpace(spec.ConsoleMode) {
	case "proxmox_termproxy":
		if kind == proxmoxTargetKindLXCGuest && vmid > 0 {
			vmidText := strconv.Itoa(vmid)
			return "/api2/json/nodes/" + node + "/lxc/" + vmidText + "/termproxy",
				"/api2/json/nodes/" + node + "/lxc/" + vmidText + "/vncwebsocket", nil
		}
		if kind != proxmoxTargetKindPVEHost {
			return "", "", errPluginHostAuthorityDenied
		}
		return "/api2/json/nodes/" + node + "/termproxy",
			"/api2/json/nodes/" + node + "/vncwebsocket", nil
	case "proxmox_vncwebsocket":
		if kind != proxmoxTargetKindQEMUGuest || vmid <= 0 {
			return "", "", errPluginHostAuthorityDenied
		}
		vmidText := strconv.Itoa(vmid)
		return "/api2/json/nodes/" + node + "/qemu/" + vmidText + "/vncproxy",
			"/api2/json/nodes/" + node + "/qemu/" + vmidText + "/vncwebsocket", nil
	default:
		return "", "", errPluginHostAuthorityDenied
	}
}

func (e *pluginExecution) protectProxmoxConsoleProxyResponse(
	binding *pluginHostAuthorityBinding,
	requestURL *url.URL,
	statusCode int,
	body []byte,
) ([]byte, error) {
	if binding == nil || e == nil || e.assignment == nil ||
		e.assignment.PluginID != proxmoxConsolePluginID {
		return body, nil
	}

	// A new provider-ticket response supersedes any prior ticket attempt. Clear
	// the old state before parsing so malformed, denied, or truncated responses
	// cannot leave a previously issued one-use ticket available for replay.
	e.clearProxmoxConsoleTicket()

	proxyPath, websocketPath, err := expectedProxmoxConsolePaths(e.consoleSessionSpec, *binding)
	if err != nil || requestURL == nil || requestURL.Path != proxyPath {
		return nil, errPluginHostAuthorityDenied
	}
	if statusCode < http.StatusOK || statusCode >= http.StatusMultipleChoices {
		return body, nil
	}

	var response struct {
		Data struct {
			Port   any    `json:"port"`
			Ticket string `json:"ticket"`
		} `json:"data"`
	}
	if err := rejectDuplicateJSONFields(body); err != nil {
		return nil, errPluginHostAuthorityDenied
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&response); err != nil {
		return nil, errPluginHostAuthorityDenied
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errPluginHostAuthorityDenied
	}
	port, ok := canonicalProxmoxConsoleProxyPort(response.Data.Port)
	if !ok || !validPluginHostAuthorityString(response.Data.Ticket) {
		return nil, errPluginHostAuthorityDenied
	}

	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}
	state := &proxmoxConsoleTicketState{
		sessionID:     strings.TrimSpace(e.consoleSessionSpec.SessionID),
		bindingID:     binding.bindingID,
		proxyPath:     proxyPath,
		websocketPath: websocketPath,
		port:          port,
		ticket:        []byte(response.Data.Ticket),
		expiresAt:     now.Add(proxmoxConsoleTicketTTL),
	}
	e.mu.Lock()
	clearProxmoxConsoleTicketState(e.proxmoxConsoleTicket)
	e.proxmoxConsoleTicket = state
	e.mu.Unlock()

	sanitized := struct {
		Data struct {
			Port   json.Number `json:"port"`
			Ticket string      `json:"ticket"`
		} `json:"data"`
	}{}
	sanitized.Data.Port = json.Number(port)
	sanitized.Data.Ticket = proxmoxConsoleTicketSentinel
	return json.Marshal(sanitized)
}

func canonicalProxmoxConsoleProxyPort(value any) (string, bool) {
	var raw string
	switch typed := value.(type) {
	case json.Number:
		raw = typed.String()
	case string:
		raw = typed
	default:
		return "", false
	}
	port, ok := parseStrictPositiveInt(raw)
	if !ok || port > 65535 || strconv.Itoa(port) != raw {
		return "", false
	}
	return raw, true
}

func (e *pluginExecution) consumeProxmoxConsoleTicket(
	requestURL *url.URL,
	binding *pluginHostAuthorityBinding,
) (*url.URL, error) {
	if e == nil || requestURL == nil || binding == nil ||
		requestURL.Query().Get("vncticket") != proxmoxConsoleTicketSentinel {
		return nil, errPluginHostAuthorityDenied
	}
	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}

	e.mu.Lock()
	defer e.mu.Unlock()
	state := e.proxmoxConsoleTicket
	if !e.proxmoxConsoleTicketMatchesLocked(state, requestURL, binding, now) {
		if state != nil && !now.Before(state.expiresAt) {
			clearProxmoxConsoleTicketState(state)
			e.proxmoxConsoleTicket = nil
		}
		return nil, errPluginHostAuthorityDenied
	}

	dialURL := *requestURL
	query := dialURL.Query()
	query.Set("vncticket", string(state.ticket))
	dialURL.RawQuery = query.Encode()
	clearProxmoxConsoleTicketState(state)
	e.proxmoxConsoleTicket = nil
	return &dialURL, nil
}

func (e *pluginExecution) hasBoundProxmoxConsoleTicket(
	requestURL *url.URL,
	binding *pluginHostAuthorityBinding,
) bool {
	if e == nil || requestURL == nil || binding == nil {
		return false
	}
	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.proxmoxConsoleTicket != nil && !now.Before(e.proxmoxConsoleTicket.expiresAt) {
		clearProxmoxConsoleTicketState(e.proxmoxConsoleTicket)
		e.proxmoxConsoleTicket = nil
		return false
	}
	return e.proxmoxConsoleTicketMatchesLocked(e.proxmoxConsoleTicket, requestURL, binding, now)
}

func (e *pluginExecution) proxmoxConsoleTicketMatchesLocked(
	state *proxmoxConsoleTicketState,
	requestURL *url.URL,
	binding *pluginHostAuthorityBinding,
	now time.Time,
) bool {
	if state == nil || requestURL == nil || binding == nil {
		return false
	}
	proxyPath, websocketPath, err := expectedProxmoxConsolePaths(e.consoleSessionSpec, *binding)
	if err != nil {
		return false
	}
	return state != nil && requestURL != nil && binding != nil && now.Before(state.expiresAt) &&
		state.sessionID == strings.TrimSpace(e.consoleSessionSpec.SessionID) &&
		state.bindingID == binding.bindingID && state.proxyPath == proxyPath &&
		state.websocketPath == websocketPath && state.websocketPath == requestURL.Path &&
		state.port == requestURL.Query().Get("port") && len(state.ticket) > 0
}

func (e *pluginExecution) clearProxmoxConsoleTicket() {
	if e == nil {
		return
	}
	e.mu.Lock()
	clearProxmoxConsoleTicketState(e.proxmoxConsoleTicket)
	e.proxmoxConsoleTicket = nil
	e.mu.Unlock()
}

func clearProxmoxConsoleTicketState(state *proxmoxConsoleTicketState) {
	if state == nil {
		return
	}
	clear(state.ticket)
	state.ticket = nil
}

func (e *pluginExecution) proxmoxHostAuthorityForWebSocket(
	requestURL *url.URL,
	headers http.Header,
	insecureSkipVerify bool,
) (*pluginHostAuthorityBinding, error) {
	if e == nil || e.assignment == nil || !e.assignment.proxmoxHostAuthorityRequired {
		return nil, nil
	}
	if e.mode != pluginExecutionModeStreaming || e.assignment.PluginID != proxmoxConsolePluginID ||
		requestURL == nil || requestURL.Scheme != webSocketSecureScheme {
		return nil, errPluginHostAuthorityDenied
	}

	httpURL := *requestURL
	httpURL.Scheme = httpsScheme
	origin, err := canonicalPluginHostAuthorityRequestOrigin(&httpURL)
	if err != nil {
		return nil, errPluginHostAuthorityDenied
	}
	binding, err := e.selectProxmoxHostAuthorityBinding(origin)
	if err != nil || binding.insecureSkipVerify != insecureSkipVerify ||
		headers.Get("Authorization") != pluginHostCredentialSentinel {
		return nil, errPluginHostAuthorityDenied
	}
	_, expectedPath, err := expectedProxmoxConsolePaths(e.consoleSessionSpec, binding)
	if err != nil || !safeCredentialRequestPath(&httpURL) || requestURL.Path != expectedPath ||
		!validProxmoxConsoleWebSocketQuery(requestURL.Query()) {
		return nil, formatPluginHostAuthorityError(binding)
	}

	now := time.Now()
	if e.manager != nil {
		now = e.manager.credentialNowTime()
	}
	if validatePluginActionCredentialGrantEnvelope(binding.credentialBroker, now) != nil ||
		!pluginHostAuthorityGrantRequestAllowed(binding.credentialBroker, http.MethodGet, &httpURL) {
		return nil, formatPluginHostAuthorityError(binding)
	}
	if !e.hasBoundProxmoxConsoleTicket(requestURL, &binding) {
		return nil, formatPluginHostAuthorityError(binding)
	}
	return &binding, nil
}

func validProxmoxConsoleWebSocketQuery(query url.Values) bool {
	if len(query) != 2 {
		return false
	}
	for _, key := range []string{"port", "vncticket"} {
		values, ok := query[key]
		if !ok || len(values) != 1 || values[0] == "" || len(values[0]) > maximumPluginHostAuthorityStringBytes {
			return false
		}
	}
	if query.Get("vncticket") != proxmoxConsoleTicketSentinel {
		return false
	}
	_, ok := parseStrictPositiveInt(query.Get("port"))
	return ok
}

func (e *pluginExecution) applyProxmoxHostAuthorityWebSocketCredential(
	ctx context.Context,
	headers http.Header,
	binding *pluginHostAuthorityBinding,
) error {
	if binding == nil {
		return nil
	}
	if headers.Get("Authorization") != pluginHostCredentialSentinel || e == nil || e.manager == nil {
		return errPluginHostAuthorityDenied
	}
	if err := e.ensureActiveProxmoxAssignment(ctx); err != nil {
		return err
	}
	material, err := e.manager.resolveCredentialBrokerMaterial(ctx, binding.credentialBroker)
	if err != nil {
		return err
	}
	value, err := proxmoxAuthorizationValue(material)
	if err != nil {
		return err
	}
	headers.Set("Authorization", value)
	return nil
}

func (e *pluginExecution) trustedProxmoxConsoleSSHConfig(
	ctx context.Context,
	sessionID string,
) (proxmoxConsoleSSHConfig, error) {
	if e == nil || e.assignment == nil || e.manager == nil ||
		!e.assignment.proxmoxHostAuthorityRequired || e.assignment.PluginID != proxmoxConsolePluginID ||
		e.mode != pluginExecutionModeStreaming || strings.TrimSpace(sessionID) == "" ||
		sessionID != e.consoleSessionSpec.SessionID || e.consoleSessionSpec.ConsoleMode != "ssh" {
		return proxmoxConsoleSSHConfig{}, errPluginHostAuthorityDenied
	}
	if err := e.ensureActiveProxmoxAssignment(ctx); err != nil {
		return proxmoxConsoleSSHConfig{}, err
	}
	origin, err := consoleSpecCanonicalOrigin(e.consoleSessionSpec)
	if err != nil {
		return proxmoxConsoleSSHConfig{}, errPluginHostAuthorityDenied
	}
	binding, err := e.selectProxmoxHostAuthorityBinding(origin)
	if err != nil {
		return proxmoxConsoleSSHConfig{}, errPluginHostAuthorityDenied
	}
	if proxmoxTargetKind(firstNonEmpty(binding.targetIDs["target_kind"], e.consoleSessionSpec.TargetKind)) != proxmoxTargetKindPVEHost ||
		(e.consoleSessionSpec.Target.SSHPort != 0 && e.consoleSessionSpec.Target.SSHPort != 22) {
		return proxmoxConsoleSSHConfig{}, formatPluginHostAuthorityError(binding)
	}

	originURL, err := url.Parse(binding.origin)
	if err != nil || originURL.Hostname() == "" || !pluginHostAuthoritySSHGrantAllowed(binding, originURL.Hostname()) {
		return proxmoxConsoleSSHConfig{}, formatPluginHostAuthorityError(binding)
	}
	now := e.manager.credentialNowTime()
	if validatePluginActionCredentialGrantEnvelope(binding.credentialBroker, now) != nil {
		return proxmoxConsoleSSHConfig{}, formatPluginHostAuthorityError(binding)
	}

	if err := e.ensureActiveProxmoxAssignment(ctx); err != nil {
		return proxmoxConsoleSSHConfig{}, err
	}
	material, err := e.manager.resolveCredentialBrokerMaterial(ctx, binding.credentialBroker)
	if err != nil {
		return proxmoxConsoleSSHConfig{}, err
	}
	credential, err := proxmoxConsoleSSHCredentialFromMaterial(material)
	if err != nil {
		return proxmoxConsoleSSHConfig{}, err
	}
	timeoutMS, err := trustedProxmoxSSHTimeout(e.assignment.ParamsJSON)
	if err != nil {
		return proxmoxConsoleSSHConfig{}, err
	}
	policy := binding.sshHostKeyPolicy
	if policy != proxmoxSSHHostKeyPolicyKnownHosts && policy != proxmoxSSHHostKeyPolicyTrustFirstUse {
		return proxmoxConsoleSSHConfig{}, formatPluginHostAuthorityError(binding)
	}

	return proxmoxConsoleSSHConfig{
		CredentialRuleID: binding.credentialRuleID,
		Console:          e.consoleSessionSpec,
		Target: proxmoxConsoleSSHTarget{
			DeviceUID:           e.consoleSessionSpec.DeviceUID,
			Hostname:            originURL.Hostname(),
			SSHPort:             22,
			ProviderRef:         firstNonEmpty(e.consoleSessionSpec.Target.ProviderRef, e.consoleSessionSpec.Target.TargetRef),
			TargetRef:           e.consoleSessionSpec.Target.TargetRef,
			TargetKind:          proxmoxTargetKindPVEHost,
			ConsoleMode:         "ssh",
			IntegrationID:       e.consoleSessionSpec.Target.IntegrationID,
			Cluster:             e.consoleSessionSpec.Target.Cluster,
			Node:                firstNonEmpty(e.consoleSessionSpec.Target.Node, e.consoleSessionSpec.Target.OwnerNode),
			VMID:                e.consoleSessionSpec.Target.VMID,
			ControllerID:        e.consoleSessionSpec.Target.ControllerID,
			ProviderInstanceRef: e.consoleSessionSpec.Target.ProviderInstanceRef,
			NativeClusterID:     e.consoleSessionSpec.Target.NativeClusterID,
			ObjectKind:          e.consoleSessionSpec.Target.ObjectKind,
			NativeObjectID:      e.consoleSessionSpec.Target.NativeObjectID,
		},
		SSH:              credential,
		TimeoutMS:        timeoutMS,
		SSHHostKeyPolicy: policy,
	}, nil
}

func pluginHostAuthoritySSHGrantAllowed(binding pluginHostAuthorityBinding, host string) bool {
	grant := binding.credentialBroker
	if len(grant.Allow.Methods) > 0 || len(grant.Allow.Paths) > 0 {
		return false
	}
	if len(grant.Allow.Hosts) > 0 && !stringInFoldedList(host, grant.Allow.Hosts) {
		return false
	}
	return len(grant.Allow.Ports) == 0 || intInList(22, grant.Allow.Ports)
}

func proxmoxConsoleSSHCredentialFromMaterial(material CredentialBrokerMaterial) (proxmoxConsoleSSHAuth, error) {
	credential := proxmoxConsoleSSHAuth{
		Username:   credentialMaterialFieldValue(material, credentialFormFieldUsername, "user"),
		Password:   credentialMaterialFieldValue(material, credentialFormFieldPassword),
		PrivateKey: credentialMaterialFieldValue(material, "private_key"),
		Passphrase: credentialMaterialFieldValue(material, "passphrase"),
	}
	if credential.Username == "" || credential.Password == "" && credential.PrivateKey == "" {
		var decoded proxmoxConsoleSSHAuth
		if decodeStrictJSON([]byte(material.Value), &decoded) == nil {
			if credential.Username == "" {
				credential.Username = decoded.Username
			}
			if credential.Password == "" {
				credential.Password = decoded.Password
			}
			if credential.PrivateKey == "" {
				credential.PrivateKey = decoded.PrivateKey
			}
			if credential.Passphrase == "" {
				credential.Passphrase = decoded.Passphrase
			}
		}
	}
	return validateProxmoxConsoleSSHCredential(credential)
}

func trustedProxmoxSSHTimeout(paramsJSON []byte) (int, error) {
	var root any
	if err := decodeStrictJSON(paramsJSON, &root); err != nil {
		return 0, errPluginHostAuthorityMalformed
	}
	timeoutMS := 30_000
	var timeouts []int
	var walk func(any) error
	walk = func(value any) error {
		switch typed := value.(type) {
		case map[string]any:
			for key, child := range typed {
				switch key {
				case "ssh_host_key_policy", "known_hosts_path":
					return errPluginHostAuthorityMalformed
				case "timeout_ms":
					number, ok := child.(json.Number)
					if !ok {
						return errPluginHostAuthorityMalformed
					}
					parsed, err := strconv.Atoi(number.String())
					if err != nil || parsed < 0 || parsed > 300_000 {
						return errPluginHostAuthorityMalformed
					}
					timeouts = append(timeouts, parsed)
				}
				if err := walk(child); err != nil {
					return err
				}
			}
		case []any:
			for _, child := range typed {
				if err := walk(child); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := walk(root); err != nil {
		return 0, err
	}
	var timeoutSet bool
	for _, candidate := range timeouts {
		if timeoutSet && candidate != timeoutMS {
			return 0, errPluginHostAuthorityMalformed
		}
		timeoutMS = candidate
		timeoutSet = true
	}
	return normalizeProxmoxConsoleTimeoutMS(timeoutMS), nil
}

func parseStrictPositiveInt(value string) (int, bool) {
	if value == "" || strings.TrimSpace(value) != value {
		return 0, false
	}
	parsed, err := strconv.Atoi(value)
	return parsed, err == nil && parsed > 0
}

func formatPluginHostAuthorityError(binding pluginHostAuthorityBinding) error {
	return fmt.Errorf("%w for binding %q", errPluginHostAuthorityDenied, binding.bindingID)
}

// maxPluginHostAuthorityCABundleBytes bounds operator-supplied trust material.
// A PVE cluster CA is a single ~2 KiB certificate; the ceiling is generous
// enough for a short chain and small enough that a malformed binding cannot
// make the agent parse an unbounded blob.
const maxPluginHostAuthorityCABundleBytes = 64 << 10

// validPluginHostAuthorityCABundle accepts an absent bundle and otherwise
// requires PEM that decodes to at least one CERTIFICATE block. It deliberately
// does not check expiry: the control plane rejects an expired bundle at save
// time, and an agent that refused a binding here would fail closed on a clock
// skew rather than surface a TLS error the operator can read.
func validPluginHostAuthorityCABundle(bundle string) bool {
	if bundle == "" {
		return true
	}
	if len(bundle) > maxPluginHostAuthorityCABundleBytes {
		return false
	}

	return pluginHostAuthorityCertPool(bundle) != nil
}

func validPluginHostAuthorityFingerprint(fingerprint string) bool {
	if fingerprint == "" {
		return true
	}

	const prefix = "sha256:"
	if !strings.HasPrefix(fingerprint, prefix) {
		return false
	}

	digest := fingerprint[len(prefix):]
	if len(digest) != 64 || digest != strings.ToLower(digest) {
		return false
	}

	_, err := hex.DecodeString(digest)
	return err == nil
}

// pluginHostAuthorityCertPool builds a pool containing only the binding's own
// trust material. It is deliberately NOT seeded from the system pool: a rule
// that pins a private CA is asking for that anchor, and adding the public roots
// back would silently accept any publicly-trusted certificate for the same
// origin, which is weaker than what the operator configured.
func pluginHostAuthorityCertPool(bundle string) *x509.CertPool {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(bundle)) {
		return nil
	}

	return pool
}
