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

package netperf

import (
	"crypto/tls"
	"fmt"

	"google.golang.org/grpc/credentials"

	"github.com/carverauto/serviceradar/go/pkg/certpolicy"
	srgrpc "github.com/carverauto/serviceradar/go/pkg/grpc"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func buildServerTransportCredentials(
	sec *models.SecurityConfig,
	provider *srgrpc.MTLSProvider,
	peerPolicy *certpolicy.Store,
	log logger.Logger,
) (credentials.TransportCredentials, *srgrpc.MTLSProvider, error) {
	if log == nil {
		log = logger.NewTestLogger()
	}
	var owned *srgrpc.MTLSProvider
	if provider == nil {
		if sec == nil || sec.Mode != models.SecurityModeMTLS {
			return nil, nil, ErrSecurityRequired
		}
		var opts []srgrpc.MTLSOption
		if peerPolicy != nil {
			opts = append(opts, srgrpc.WithPeerCertificatePolicy(peerPolicy))
		}
		created, err := srgrpc.NewPeerMTLSProvider(sec, log, opts...)
		if err != nil {
			return nil, nil, fmt.Errorf("create peer server mTLS provider: %w", err)
		}
		provider = created
		owned = created
	}

	creds, err := provider.PeerServerCredentials(func(cfg *tls.Config) {
		cfg.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.VerifiedChains) == 0 || len(cs.PeerCertificates) == 0 {
				return ErrPeerIdentityInvalid
			}
			_, idErr := ExtractPeerIdentityFromCert(cs.PeerCertificates[0])
			return idErr
		}
	})
	if err != nil {
		if owned != nil {
			_ = owned.Close()
		}
		return nil, nil, err
	}
	return creds, owned, nil
}

func buildClientTransportCredentials(
	sec *models.SecurityConfig,
	provider *srgrpc.MTLSProvider,
	peerPolicy *certpolicy.Store,
	expectedAgentID string,
	expectedPartitionID string,
	log logger.Logger,
) (credentials.TransportCredentials, *srgrpc.MTLSProvider, error) {
	if log == nil {
		log = logger.NewTestLogger()
	}
	var owned *srgrpc.MTLSProvider
	if provider == nil {
		if sec == nil || sec.Mode != models.SecurityModeMTLS {
			return nil, nil, ErrSecurityRequired
		}
		var opts []srgrpc.MTLSOption
		if peerPolicy != nil {
			opts = append(opts, srgrpc.WithPeerCertificatePolicy(peerPolicy))
		}
		created, err := srgrpc.NewPeerMTLSProvider(sec, log, opts...)
		if err != nil {
			return nil, nil, fmt.Errorf("create peer client mTLS provider: %w", err)
		}
		provider = created
		owned = created
	}

	serverName := expectedAgentID + "." + expectedPartitionID + serviceRadarDNSSuffix
	creds, err := provider.PeerClientCredentials(serverName, func(cfg *tls.Config) {
		cfg.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.VerifiedChains) == 0 || len(cs.PeerCertificates) == 0 {
				return ErrPeerIdentityInvalid
			}
			id, idErr := ExtractPeerIdentityFromCert(cs.PeerCertificates[0])
			if idErr != nil {
				return idErr
			}
			if id.AgentID != expectedAgentID || id.PartitionID != expectedPartitionID {
				return fmt.Errorf("%w: got %s.%s, want %s.%s",
					ErrPeerIdentityMismatch, id.AgentID, id.PartitionID, expectedAgentID, expectedPartitionID)
			}
			if leaf := provider.ClientLeaf(); leaf != nil {
				if localID, localErr := ExtractPeerIdentityFromCert(leaf); localErr == nil {
					if localID.TrustDomain != "" && id.TrustDomain != "" && localID.TrustDomain != id.TrustDomain {
						return fmt.Errorf("%w: trust domain %q != %q",
							ErrPeerIdentityMismatch, id.TrustDomain, localID.TrustDomain)
					}
				}
			}
			return nil
		}
	})
	if err != nil {
		if owned != nil {
			_ = owned.Close()
		}
		return nil, nil, err
	}
	return creds, owned, nil
}
