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
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

var errCredentialBrokerResolutionDenied = errors.New("credential broker resolution denied")

type credentialGrantGateway interface {
	ResolveCredentialGrant(context.Context, *proto.CredentialBrokerResolveRequest) (*proto.CredentialBrokerResolveResponse, error)
}

type controlPlaneCredentialBrokerResolver struct {
	gateway credentialGrantGateway
	agentID string
}

func newControlPlaneCredentialBrokerResolver(gateway credentialGrantGateway, agentID string) CredentialBrokerResolver {
	if gateway == nil || strings.TrimSpace(agentID) == "" {
		return nil
	}

	return controlPlaneCredentialBrokerResolver{
		gateway: gateway,
		agentID: strings.TrimSpace(agentID),
	}
}

func (r controlPlaneCredentialBrokerResolver) ResolveCredentialGrant(
	ctx context.Context,
	grant credentialBrokerGrant,
) (CredentialBrokerMaterial, error) {
	if r.gateway == nil {
		return CredentialBrokerMaterial{}, errCredentialBrokerResolverUnavailable
	}

	resp, err := r.gateway.ResolveCredentialGrant(ctx, &proto.CredentialBrokerResolveRequest{
		AgentId:             r.agentID,
		GrantId:             strings.TrimSpace(grant.GrantID),
		CredentialSecretRef: strings.TrimSpace(grant.CredentialSecretRef),
		ConsumerKind:        strings.TrimSpace(grant.Consumer["kind"]),
		ConsumerId:          strings.TrimSpace(grant.Consumer["id"]),
		Purpose:             strings.TrimSpace(grant.Consumer["purpose"]),
		ResolutionLocation:  strings.TrimSpace(grant.ResolutionLocation),
	})
	if err != nil {
		return CredentialBrokerMaterial{}, err
	}
	if resp == nil {
		return CredentialBrokerMaterial{}, fmt.Errorf("%w: empty response", errCredentialBrokerResolutionDenied)
	}
	if !resp.GetSuccess() {
		message := strings.TrimSpace(resp.GetMessage())
		if message == "" {
			message = "grant resolution denied"
		}

		return CredentialBrokerMaterial{}, fmt.Errorf("%w: %s", errCredentialBrokerResolutionDenied, message)
	}

	return CredentialBrokerMaterial{
		Value:          resp.GetValue(),
		Fields:         cloneCredentialBrokerFields(resp.GetFields()),
		LeaseExpiresAt: credentialBrokerLeaseExpiresAt(resp.GetLeaseExpiresAtUnix()),
	}, nil
}

func credentialBrokerLeaseExpiresAt(unixSeconds int64) time.Time {
	if unixSeconds <= 0 {
		return time.Time{}
	}

	return time.Unix(unixSeconds, 0).UTC()
}

func cloneCredentialBrokerFields(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}

	clone := make(map[string]string, len(values))
	for key, value := range values {
		clone[key] = value
	}

	return clone
}
