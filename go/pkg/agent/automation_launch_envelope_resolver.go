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
	"context"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"github.com/google/uuid"
)

var errAutomationLaunchEnvelopeDenied = errors.New("automation launch envelope resolution denied")

const (
	launchEnvelopeReferencePrefix = "srle1_"
	callbackIdempotencyKeyPrefix  = "srci_v1_"
	maxLaunchEnvelopeTTL          = 10 * time.Minute
)

type automationLaunchEnvelopeGateway interface {
	ResolveAutomationLaunchEnvelope(context.Context, *proto.AutomationLaunchEnvelopeResolveRequest) (*proto.AutomationLaunchEnvelopeResolveResponse, error)
}

// AutomationLaunchEnvelopeMaterial keeps every callback input in caller-owned
// byte buffers so the caller can clear the complete material set as soon as
// the AWX credential request finishes. No callback input may be placed in a
// command result, log field, fact, or managed-host payload.
type AutomationLaunchEnvelopeMaterial struct {
	Bearer                           []byte
	IdempotencyKey                   []byte
	CallbackURL                      []byte
	CallbackAllowedOrigin            []byte
	ManifestSHA256                   []byte
	SCMRevision                      []byte
	ContentSHA256                    []byte
	CallbackPhase                    []byte
	CallbackOperation                []byte
	CallbackState                    []byte
	CallbackCredentialInjectorSHA256 []byte
	CallbackGrantID                  string
	ControllerID                     string
	ChildExecutionID                 string
	DispatchAgentID                  string
	CommandID                        string
	InventoryID                      int
	JobTemplateID                    int
	CallbackCredentialTypeID         int
	CallbackCredentialOrganizationID int
	ExpiresAt                        time.Time
}

// Destroy best-effort clears every mutable callback-input buffer.
func (m *AutomationLaunchEnvelopeMaterial) Destroy() {
	if m == nil {
		return
	}

	for _, value := range m.mutableBuffers() {
		zeroBytes(value)
	}
	m.Bearer = nil
	m.IdempotencyKey = nil
	m.CallbackURL = nil
	m.CallbackAllowedOrigin = nil
	m.ManifestSHA256 = nil
	m.SCMRevision = nil
	m.ContentSHA256 = nil
	m.CallbackPhase = nil
	m.CallbackOperation = nil
	m.CallbackState = nil
	m.CallbackCredentialInjectorSHA256 = nil
}

func (m *AutomationLaunchEnvelopeMaterial) mutableBuffers() [][]byte {
	if m == nil {
		return nil
	}

	return [][]byte{
		m.Bearer,
		m.IdempotencyKey,
		m.CallbackURL,
		m.CallbackAllowedOrigin,
		m.ManifestSHA256,
		m.SCMRevision,
		m.ContentSHA256,
		m.CallbackPhase,
		m.CallbackOperation,
		m.CallbackState,
		m.CallbackCredentialInjectorSHA256,
	}
}

type controlPlaneAutomationLaunchEnvelopeResolver struct {
	gateway automationLaunchEnvelopeGateway
	agentID string
	now     func() time.Time
}

func newControlPlaneAutomationLaunchEnvelopeResolver(
	gateway automationLaunchEnvelopeGateway,
	agentID string,
) *controlPlaneAutomationLaunchEnvelopeResolver {
	if gateway == nil || strings.TrimSpace(agentID) == "" {
		return nil
	}

	return &controlPlaneAutomationLaunchEnvelopeResolver{
		gateway: gateway,
		agentID: strings.TrimSpace(agentID),
		now:     time.Now,
	}
}

func (r *controlPlaneAutomationLaunchEnvelopeResolver) Resolve(
	ctx context.Context,
	envelopeRef string,
	commandID string,
) (AutomationLaunchEnvelopeMaterial, error) {
	if r == nil || r.gateway == nil {
		return AutomationLaunchEnvelopeMaterial{}, errAutomationLaunchEnvelopeDenied
	}

	envelopeRef = strings.TrimSpace(envelopeRef)
	commandID = strings.TrimSpace(commandID)
	canonicalCommandID, validCommandID := canonicalLaunchCommandID(commandID)
	if !validLaunchEnvelopeReference(envelopeRef) || !validCommandID {
		return AutomationLaunchEnvelopeMaterial{}, errAutomationLaunchEnvelopeDenied
	}

	resp, err := r.gateway.ResolveAutomationLaunchEnvelope(
		ctx,
		&proto.AutomationLaunchEnvelopeResolveRequest{
			AgentId:     r.agentID,
			EnvelopeRef: envelopeRef,
			CommandId:   canonicalCommandID,
		},
	)
	if err != nil {
		return AutomationLaunchEnvelopeMaterial{}, err
	}
	if resp == nil {
		return AutomationLaunchEnvelopeMaterial{}, fmt.Errorf("%w: empty response", errAutomationLaunchEnvelopeDenied)
	}

	responseBuffers := automationLaunchEnvelopeResponseBuffers(resp)
	defer zeroByteBuffers(responseBuffers)
	bearer := resp.GetBearer()
	idempotencyKey := resp.GetIdempotencyKey()
	callbackGrantID, validGrantID := canonicalLaunchCommandID(resp.GetCallbackGrantId())
	expiresAt := launchEnvelopeExpiresAt(resp.GetExpiresAtUnix())
	now := time.Now
	if r.now != nil {
		now = r.now
	}
	currentTime := now().UTC()

	if !resp.GetSuccess() || !validCallbackBearer(bearer) ||
		!validCallbackIdempotencyKey(idempotencyKey) || !validGrantID ||
		expiresAt.IsZero() || !expiresAt.After(currentTime) ||
		expiresAt.After(currentTime.Add(maxLaunchEnvelopeTTL)) ||
		resp.GetDispatchAgentId() != r.agentID ||
		resp.GetCommandId() != canonicalCommandID ||
		!validLaunchEnvelopeCorrelation(resp) {
		return AutomationLaunchEnvelopeMaterial{}, errAutomationLaunchEnvelopeDenied
	}

	return AutomationLaunchEnvelopeMaterial{
		Bearer:                           cloneMutableBytes(bearer),
		IdempotencyKey:                   cloneMutableBytes(idempotencyKey),
		CallbackURL:                      cloneMutableBytes(resp.GetCallbackUrl()),
		CallbackAllowedOrigin:            cloneMutableBytes(resp.GetCallbackAllowedOrigin()),
		ManifestSHA256:                   cloneMutableBytes(resp.GetManifestSha256()),
		SCMRevision:                      cloneMutableBytes(resp.GetScmRevision()),
		ContentSHA256:                    cloneMutableBytes(resp.GetContentSha256()),
		CallbackPhase:                    cloneMutableBytes(resp.GetCallbackPhase()),
		CallbackOperation:                cloneMutableBytes(resp.GetCallbackOperation()),
		CallbackState:                    cloneMutableBytes(resp.GetCallbackState()),
		CallbackCredentialInjectorSHA256: cloneMutableBytes(resp.GetCallbackCredentialInjectorSha256()),
		CallbackGrantID:                  callbackGrantID,
		ControllerID:                     resp.GetControllerId(),
		ChildExecutionID:                 resp.GetChildExecutionId(),
		DispatchAgentID:                  resp.GetDispatchAgentId(),
		CommandID:                        resp.GetCommandId(),
		InventoryID:                      int(resp.GetInventoryId()),
		JobTemplateID:                    int(resp.GetJobTemplateId()),
		CallbackCredentialTypeID:         int(resp.GetCallbackCredentialTypeId()),
		CallbackCredentialOrganizationID: int(resp.GetCallbackCredentialOrganizationId()),
		ExpiresAt:                        expiresAt,
	}, nil
}

// ResolveAWXCallbackCredentialEnvelope bridges the single-use control-plane
// envelope to the exact in-memory material expected by the AWX host boundary.
// Every response coordinate is compared with the reviewed durable binding;
// command arguments are never a source for callback input values.
func (r *controlPlaneAutomationLaunchEnvelopeResolver) ResolveAWXCallbackCredentialEnvelope(
	ctx context.Context,
	binding AWXCallbackCredentialBinding,
) (AWXCallbackCredentialMaterial, error) {
	resolved, err := r.Resolve(ctx, binding.EnvelopeRef, binding.CommandID)
	if err != nil {
		return AWXCallbackCredentialMaterial{}, errAWXCallbackCredentialResolutionDenied
	}
	defer resolved.Destroy()

	if !automationLaunchEnvelopeMatchesAWXBinding(resolved, binding) {
		return AWXCallbackCredentialMaterial{}, errAWXCallbackCredentialResolutionDenied
	}

	material := AWXCallbackCredentialMaterial{
		CallbackURL:            cloneMutableBytes(resolved.CallbackURL),
		CallbackGrant:          cloneMutableBytes(resolved.Bearer),
		CallbackIdempotencyKey: cloneMutableBytes(resolved.IdempotencyKey),
		CallbackAllowedOrigin:  cloneMutableBytes(resolved.CallbackAllowedOrigin),
		CallbackManifestSHA256: cloneMutableBytes(resolved.ManifestSHA256),
		SCMRevision:            cloneMutableBytes(resolved.SCMRevision),
		ContentSHA256:          cloneMutableBytes(resolved.ContentSHA256),
		CallbackPhase:          cloneMutableBytes(resolved.CallbackPhase),
		CallbackOperation:      cloneMutableBytes(resolved.CallbackOperation),
		CallbackState:          cloneMutableBytes(resolved.CallbackState),
		ExpiresAt:              resolved.ExpiresAt,
	}

	grantID := []byte(resolved.CallbackGrantID)
	defer zeroBytes(grantID)
	if err := validateAWXCallbackCredentialMaterial(material, resolverNow(r)); err != nil ||
		!callbackURLMatchesGrant(material.CallbackURL, material.CallbackAllowedOrigin, grantID) {
		material.destroy()
		return AWXCallbackCredentialMaterial{}, errAWXCallbackCredentialResolutionDenied
	}

	return material, nil
}

func automationLaunchEnvelopeMatchesAWXBinding(
	resolved AutomationLaunchEnvelopeMaterial,
	binding AWXCallbackCredentialBinding,
) bool {
	return resolved.DispatchAgentID == strings.TrimSpace(binding.DispatchAgentID) &&
		resolved.CommandID == strings.TrimSpace(binding.CommandID) &&
		resolved.ControllerID == strings.TrimSpace(binding.ControllerID) &&
		resolved.ChildExecutionID == strings.TrimSpace(binding.ChildExecutionID) &&
		resolved.InventoryID == binding.InventoryID &&
		resolved.JobTemplateID == binding.JobTemplateID &&
		resolved.CallbackCredentialTypeID == binding.CredentialTypeID &&
		resolved.CallbackCredentialOrganizationID == binding.OrganizationID &&
		constantTimeBytesEqual(resolved.CallbackCredentialInjectorSHA256, []byte(binding.InjectorSHA256))
}

func callbackURLMatchesGrant(callbackURL, allowedOrigin, grantID []byte) bool {
	expected := make([]byte, 0, len(allowedOrigin)+len(grantID)+96)
	expected = append(expected, allowedOrigin...)
	expected = append(expected, "/api/v1/automation/callback-grants/"...)
	expected = append(expected, grantID...)
	expected = append(expected, "/actions/remote_access.ssh_ca.bundle.read"...)
	defer zeroBytes(expected)

	return constantTimeBytesEqual(callbackURL, expected)
}

func validLaunchEnvelopeCorrelation(resp *proto.AutomationLaunchEnvelopeResolveResponse) bool {
	if resp == nil || strings.TrimSpace(resp.GetControllerId()) == "" ||
		strings.TrimSpace(resp.GetChildExecutionId()) == "" ||
		strings.TrimSpace(resp.GetDispatchAgentId()) == "" ||
		strings.TrimSpace(resp.GetCommandId()) == "" {
		return false
	}

	return positiveProtoAWXID(resp.GetInventoryId()) &&
		positiveProtoAWXID(resp.GetJobTemplateId()) &&
		positiveProtoAWXID(resp.GetCallbackCredentialTypeId()) &&
		positiveProtoAWXID(resp.GetCallbackCredentialOrganizationId())
}

func positiveProtoAWXID(value int64) bool {
	return value > 0 && value <= math.MaxInt32
}

func automationLaunchEnvelopeResponseBuffers(resp *proto.AutomationLaunchEnvelopeResolveResponse) [][]byte {
	if resp == nil {
		return nil
	}

	return [][]byte{
		resp.GetBearer(),
		resp.GetIdempotencyKey(),
		resp.GetCallbackUrl(),
		resp.GetCallbackAllowedOrigin(),
		resp.GetManifestSha256(),
		resp.GetScmRevision(),
		resp.GetContentSha256(),
		resp.GetCallbackPhase(),
		resp.GetCallbackOperation(),
		resp.GetCallbackState(),
		resp.GetCallbackCredentialInjectorSha256(),
	}
}

func zeroByteBuffers(buffers [][]byte) {
	for _, buffer := range buffers {
		zeroBytes(buffer)
	}
}

func cloneMutableBytes(value []byte) []byte {
	if value == nil {
		return nil
	}
	return append([]byte(nil), value...)
}

func constantTimeBytesEqual(left, right []byte) bool {
	return len(left) == len(right) && subtle.ConstantTimeCompare(left, right) == 1
}

func resolverNow(resolver *controlPlaneAutomationLaunchEnvelopeResolver) time.Time {
	if resolver != nil && resolver.now != nil {
		return resolver.now().UTC()
	}
	return time.Now().UTC()
}

func launchEnvelopeExpiresAt(unixSeconds int64) time.Time {
	if unixSeconds <= 0 {
		return time.Time{}
	}

	return time.Unix(unixSeconds, 0).UTC()
}

func zeroBytes(value []byte) {
	for index := range value {
		value[index] = 0
	}
}

func validLaunchEnvelopeReference(value string) bool {
	encoded, found := strings.CutPrefix(value, launchEnvelopeReferencePrefix)
	return found && validRawURLToken([]byte(encoded), 32)
}

func validCallbackBearer(value []byte) bool {
	return validRawURLToken(value, 32)
}

func validCallbackIdempotencyKey(value []byte) bool {
	encoded, found := bytesCutPrefix(value, []byte(callbackIdempotencyKeyPrefix))
	return found && validRawURLToken(encoded, 32)
}

func validRawURLToken(value []byte, expectedBytes int) bool {
	decoded := make([]byte, base64.RawURLEncoding.DecodedLen(len(value)))
	defer zeroBytes(decoded)

	decodedBytes, err := base64.RawURLEncoding.Decode(decoded, value)
	return err == nil && decodedBytes == expectedBytes
}

func bytesCutPrefix(value, prefix []byte) ([]byte, bool) {
	if len(value) < len(prefix) {
		return nil, false
	}
	for index := range prefix {
		if value[index] != prefix[index] {
			return nil, false
		}
	}

	return value[len(prefix):], true
}

func canonicalLaunchCommandID(value string) (string, bool) {
	parsed, err := uuid.Parse(strings.TrimSpace(value))
	if err != nil {
		return "", false
	}

	return parsed.String(), true
}
