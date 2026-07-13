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
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"github.com/google/uuid"
)

var errAutomationLaunchEnvelopeDenied = errors.New("automation launch envelope resolution denied")

const (
	launchEnvelopeReferencePrefix = "srle1_"
	callbackIdempotencyKeyPrefix  = "srci_v1_"
)

type automationLaunchEnvelopeGateway interface {
	ResolveAutomationLaunchEnvelope(context.Context, *proto.AutomationLaunchEnvelopeResolveRequest) (*proto.AutomationLaunchEnvelopeResolveResponse, error)
}

// AutomationLaunchEnvelopeMaterial is intentionally byte-backed so the caller
// can zero the one-time bearer and idempotency key as soon as the AWX
// credential request finishes. Neither value may be placed in a command
// result, log field, fact, or managed-host payload.
type AutomationLaunchEnvelopeMaterial struct {
	Bearer          []byte
	IdempotencyKey  []byte
	CallbackGrantID string
	ExpiresAt       time.Time
}

// Destroy best-effort clears the mutable bearer and idempotency-key buffers.
func (m *AutomationLaunchEnvelopeMaterial) Destroy() {
	if m == nil {
		return
	}

	zeroBytes(m.Bearer)
	zeroBytes(m.IdempotencyKey)
	m.Bearer = nil
	m.IdempotencyKey = nil
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

	bearer := resp.GetBearer()
	defer zeroBytes(bearer)
	idempotencyKey := resp.GetIdempotencyKey()
	defer zeroBytes(idempotencyKey)
	callbackGrantID, validGrantID := canonicalLaunchCommandID(resp.GetCallbackGrantId())
	expiresAt := launchEnvelopeExpiresAt(resp.GetExpiresAtUnix())
	now := time.Now
	if r.now != nil {
		now = r.now
	}

	if !resp.GetSuccess() || !validCallbackBearer(bearer) ||
		!validCallbackIdempotencyKey(idempotencyKey) || !validGrantID ||
		expiresAt.IsZero() || !expiresAt.After(now().UTC()) {
		return AutomationLaunchEnvelopeMaterial{}, errAutomationLaunchEnvelopeDenied
	}

	return AutomationLaunchEnvelopeMaterial{
		Bearer:          append([]byte(nil), bearer...),
		IdempotencyKey:  append([]byte(nil), idempotencyKey...),
		CallbackGrantID: callbackGrantID,
		ExpiresAt:       expiresAt,
	}, nil
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
