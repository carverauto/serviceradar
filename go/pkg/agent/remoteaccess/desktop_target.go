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
	"encoding/json"
	"fmt"
	"strings"
)

// DecodeDesktopOpenPayload decodes and validates a trusted desktop open-frame
// payload before an agent adapter dials the target.
func DecodeDesktopOpenPayload(data []byte) (DesktopOpenPayload, error) {
	var payload DesktopOpenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return payload, fmt.Errorf("%w: decode open payload: %w", ErrInvalidDesktopTarget, err)
	}
	payload.ActorID = strings.TrimSpace(payload.ActorID)

	target, err := NormalizeDesktopTarget(payload.Target)
	if err != nil {
		return payload, err
	}
	payload.Target = target

	if payload.CredentialGrant != nil {
		grant, err := NormalizeDesktopCredentialGrant(*payload.CredentialGrant, target)
		if err != nil {
			return payload, err
		}
		payload.CredentialGrant = &grant
	}

	return payload, nil
}

// DecodeDesktopOpenFrameForAgent decodes a trusted desktop open frame and
// enforces that the selected route is bound to the local agent before an
// adapter dials the target.
func DecodeDesktopOpenFrameForAgent(frame Frame, localAgentID string) (DesktopOpenPayload, error) {
	var payload DesktopOpenPayload

	localAgentID = strings.TrimSpace(localAgentID)
	if frame.SessionID == "" {
		return payload, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopTarget)
	}
	if localAgentID == "" {
		return payload, fmt.Errorf("%w: missing local agent binding", ErrInvalidDesktopTarget)
	}
	if frame.FrameType != FrameTypeOpen {
		return payload, fmt.Errorf("%w: expected open frame", ErrInvalidDesktopTarget)
	}
	if !validDesktopProtocol(frame.Protocol) {
		return payload, fmt.Errorf("%w: unsupported protocol", ErrInvalidDesktopTarget)
	}

	payload, err := DecodeDesktopOpenPayload(frame.Data)
	if err != nil {
		return payload, err
	}
	if err := ValidateDesktopRouteBinding(payload.Target, localAgentID, ""); err != nil {
		return payload, err
	}
	if payload.CredentialGrant != nil &&
		payload.CredentialGrant.SessionID != "" &&
		payload.CredentialGrant.SessionID != frame.SessionID {
		return payload, fmt.Errorf("%w: credential grant session mismatch", ErrInvalidDesktopTarget)
	}

	return payload, nil
}

// NormalizeDesktopTarget applies secure defaults and validates the registered
// desktop target policy snapshot.
func NormalizeDesktopTarget(target DesktopTarget) (DesktopTarget, error) {
	target.TargetID = strings.TrimSpace(target.TargetID)
	target.Protocol = strings.TrimSpace(target.Protocol)
	target.Route.SelectedAgentID = strings.TrimSpace(target.Route.SelectedAgentID)
	target.Route.SelectedGateway = strings.TrimSpace(target.Route.SelectedGateway)
	target.Route.AllowedAgentIDs = normalizeDesktopStringList(target.Route.AllowedAgentIDs)
	target.Upstream.Host = strings.TrimSpace(target.Upstream.Host)
	target.TLS.Mode = strings.TrimSpace(target.TLS.Mode)
	target.TLS.CABundleID = strings.TrimSpace(target.TLS.CABundleID)
	target.TLS.CABundlePEM = strings.TrimSpace(target.TLS.CABundlePEM)
	target.TLS.NLAMode = strings.TrimSpace(target.TLS.NLAMode)
	target.TLS.ServerName = strings.TrimSpace(target.TLS.ServerName)
	target.Credential.Mode = strings.TrimSpace(target.Credential.Mode)
	target.Credential.AllowedPrincipals = normalizeDesktopStringList(target.Credential.AllowedPrincipals)
	target.Credential.CredentialSecretRef = strings.TrimSpace(target.Credential.CredentialSecretRef)

	if target.Protocol == "" {
		target.Protocol = ProtocolRDP
	}
	if target.Upstream.Port == 0 && target.Protocol == ProtocolRDP {
		target.Upstream.Port = DesktopDefaultRDPPort
	}
	if target.TLS.Mode == "" {
		target.TLS.Mode = DesktopDefaultTLSPolicy
	}
	if target.TLS.NLAMode == "" && target.Protocol == ProtocolRDP {
		target.TLS.NLAMode = DesktopDefaultNLAPolicy
	}
	target.Screen = normalizeDesktopScreenPolicy(target.Screen)
	target.Redirection = normalizeDesktopRedirectionPolicy(target.Redirection)
	if !target.Recording.MetadataEnabled &&
		!target.Recording.ScreenEnabled &&
		!target.Recording.ClipboardEnabled &&
		!target.Recording.FileEnabled &&
		!target.Recording.AudioEnabled {
		target.Recording.MetadataEnabled = true
	}

	if err := validateDesktopTarget(target); err != nil {
		return target, err
	}

	return target, nil
}

func normalizeDesktopScreenPolicy(policy DesktopScreenPolicy) DesktopScreenPolicy {
	if policy.MaxWidth == 0 {
		policy.MaxWidth = DesktopDefaultMaxWidth
	}
	if policy.MaxHeight == 0 {
		policy.MaxHeight = DesktopDefaultMaxHeight
	}
	if policy.FrameRate == 0 {
		policy.FrameRate = DesktopDefaultFrameRate
	}
	if policy.BitrateBPS == 0 {
		policy.BitrateBPS = DesktopDefaultBitrateBPS
	}
	if policy.IdleSeconds == 0 {
		policy.IdleSeconds = DesktopDefaultIdleSec
	}
	if policy.TTLSeconds == 0 {
		policy.TTLSeconds = DesktopDefaultTTLSec
	}

	return policy
}

func normalizeDesktopRedirectionPolicy(policy DesktopRedirectionPolicy) DesktopRedirectionPolicy {
	policy.ClipboardMode = strings.TrimSpace(policy.ClipboardMode)
	if policy.ClipboardMode == "" {
		policy.ClipboardMode = DesktopClipboardModeDisabled
	}

	return policy
}

func validateDesktopTarget(target DesktopTarget) error {
	if target.TargetID == "" {
		return fmt.Errorf("%w: missing target id", ErrInvalidDesktopTarget)
	}
	if !validDesktopProtocol(target.Protocol) {
		return fmt.Errorf("%w: unsupported protocol", ErrInvalidDesktopTarget)
	}
	if target.Route.SelectedAgentID == "" {
		return fmt.Errorf("%w: missing selected agent", ErrInvalidDesktopTarget)
	}
	if !desktopStringListAllows(target.Route.AllowedAgentIDs, target.Route.SelectedAgentID) {
		return fmt.Errorf("%w: selected agent outside allowed route set", ErrInvalidDesktopTarget)
	}
	if target.Upstream.Host == "" || target.Upstream.Port == 0 || target.Upstream.Port > 65_535 {
		return fmt.Errorf("%w: invalid upstream", ErrInvalidDesktopTarget)
	}
	if !validDesktopTLSMode(target.TLS.Mode) {
		return fmt.Errorf("%w: invalid tls mode", ErrInvalidDesktopTarget)
	}
	if err := validateDesktopCABundlePolicy(target.TLS); err != nil {
		return err
	}
	if !validDesktopNLAMode(target.TLS.NLAMode) {
		return fmt.Errorf("%w: invalid nla mode", ErrInvalidDesktopTarget)
	}
	if !validDesktopCredentialMode(target.Credential.Mode) {
		return fmt.Errorf("%w: invalid credential mode", ErrInvalidDesktopTarget)
	}
	if target.Credential.Mode == DesktopCredentialModeBrokeredSecret {
		if target.Credential.CredentialSecretRef == "" {
			return fmt.Errorf("%w: brokered secret mode requires secret reference", ErrInvalidDesktopTarget)
		}
		if !target.ApprovalRequired {
			return fmt.Errorf("%w: brokered secret mode requires approval", ErrInvalidDesktopTarget)
		}
	}
	if err := validateDesktopScreenPolicy(target.Screen); err != nil {
		return err
	}
	if !validDesktopClipboardMode(target.Redirection.ClipboardMode) {
		return fmt.Errorf("%w: invalid clipboard mode", ErrInvalidDesktopTarget)
	}

	return nil
}

func validateDesktopCABundlePolicy(policy DesktopTLSPolicy) error {
	if len(policy.CABundlePEM) > DesktopMaxCABundlePEM {
		return fmt.Errorf("%w: ca_bundle_pem too large", ErrInvalidDesktopTarget)
	}
	if policy.CABundleID == "" && policy.CABundlePEM != "" {
		return fmt.Errorf("%w: ca_bundle_pem requires ca_bundle_id", ErrInvalidDesktopTarget)
	}
	if policy.CABundleID != "" && policy.CABundlePEM == "" {
		return fmt.Errorf("%w: ca_bundle_id requires ca_bundle_pem", ErrInvalidDesktopTarget)
	}
	if policy.Mode == DesktopTLSModePinnedCA && policy.CABundleID == "" {
		return fmt.Errorf("%w: pinned_ca requires ca_bundle_id", ErrInvalidDesktopTarget)
	}

	return nil
}

func validateDesktopScreenPolicy(policy DesktopScreenPolicy) error {
	if policy.MaxWidth == 0 || policy.MaxWidth > DesktopMaxWidth ||
		policy.MaxHeight == 0 || policy.MaxHeight > DesktopMaxHeight ||
		policy.FrameRate == 0 || policy.FrameRate > DesktopMaxFrameRate ||
		policy.BitrateBPS == 0 || policy.BitrateBPS > DesktopMaxBitrateBPS ||
		policy.IdleSeconds == 0 ||
		policy.TTLSeconds == 0 {
		return fmt.Errorf("%w: invalid screen policy", ErrInvalidDesktopTarget)
	}

	return nil
}

func normalizeDesktopStringList(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	normalized := values[:0]
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			normalized = append(normalized, value)
		}
	}

	return normalized
}

func desktopStringListAllows(allowed []string, value string) bool {
	if len(allowed) == 0 {
		return true
	}

	return desktopStringListContains(allowed, value)
}

func desktopStringListContains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}

	return false
}

func validDesktopTLSMode(mode string) bool {
	switch mode {
	case DesktopTLSModeVerify, DesktopTLSModePinnedCA, DesktopTLSModeInsecure, DesktopTLSModeSystem, DesktopTLSModeTOFU:
		return true
	default:
		return false
	}
}

func validDesktopNLAMode(mode string) bool {
	switch mode {
	case "", DesktopNLAModeRequired, DesktopNLAModeDisabled:
		return true
	default:
		return false
	}
}

func validDesktopCredentialMode(mode string) bool {
	switch mode {
	case DesktopCredentialModeDomainDelegation,
		DesktopCredentialModeMemoryUser,
		DesktopCredentialModeSmartCard,
		DesktopCredentialModeBrokeredSecret:
		return true
	default:
		return false
	}
}

func validDesktopClipboardMode(mode string) bool {
	switch mode {
	case DesktopClipboardModeDisabled,
		DesktopClipboardModeTextToRemote,
		DesktopClipboardModeTextToBrowser,
		DesktopClipboardModeTextBoth:
		return true
	default:
		return false
	}
}
