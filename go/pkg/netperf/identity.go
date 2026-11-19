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
	"context"
	"crypto/x509"
	"fmt"
	"strings"

	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

const serviceRadarDNSSuffix = ".serviceradar"

// PeerIdentity represents the verified ServiceRadar component identity extracted
// from an mTLS leaf certificate.
type PeerIdentity struct {
	AgentID     string
	PartitionID string
	TrustDomain string
}

// ExtractPeerIdentity reads the verified TLS leaf certificate from gRPC peer context
// and extracts its authenticated (agent_id, partition_id) identity.
func ExtractPeerIdentity(ctx context.Context) (PeerIdentity, error) {
	p, ok := peer.FromContext(ctx)
	if !ok || p == nil || p.AuthInfo == nil {
		return PeerIdentity{}, ErrPeerIdentityInvalid
	}
	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.VerifiedChains) == 0 || len(tlsInfo.State.VerifiedChains[0]) == 0 {
		return PeerIdentity{}, ErrPeerIdentityInvalid
	}
	return ExtractPeerIdentityFromCert(tlsInfo.State.VerifiedChains[0][0])
}

// ExtractPeerIdentityFromCert extracts and cross-checks the ServiceRadar agent
// identity from CN/DNS SAN (`<agent_id>.<partition_id>.serviceradar`) and any
// SPIFFE URI SAN (`spiffe://<trust_domain>/agent/<partition_id>/<agent_id>`).
func ExtractPeerIdentityFromCert(leaf *x509.Certificate) (PeerIdentity, error) {
	if leaf == nil {
		return PeerIdentity{}, ErrPeerIdentityInvalid
	}

	var dnsID PeerIdentity
	hasDNS := false

	mergeDNS := func(candidate string) error {
		parsed, ok, err := parseServiceRadarDNSIdentity(candidate)
		if err != nil {
			return err
		}
		if !ok {
			return nil
		}
		if hasDNS && (parsed.AgentID != dnsID.AgentID || parsed.PartitionID != dnsID.PartitionID) {
			return ErrPeerIdentityConflict
		}
		dnsID = parsed
		hasDNS = true
		return nil
	}

	if err := mergeDNS(leaf.Subject.CommonName); err != nil {
		return PeerIdentity{}, err
	}
	for _, dnsName := range leaf.DNSNames {
		if err := mergeDNS(dnsName); err != nil {
			return PeerIdentity{}, err
		}
	}

	var spiffeID PeerIdentity
	hasSPIFFE := false
	for _, uri := range leaf.URIs {
		if uri == nil || !strings.EqualFold(uri.Scheme, "spiffe") {
			continue
		}
		if hasSPIFFE {
			return PeerIdentity{}, ErrPeerIdentityConflict
		}
		parsed, err := parseSPIFFEAgentURI(uri.Host, uri.Path)
		if err != nil {
			return PeerIdentity{}, err
		}
		spiffeID = parsed
		hasSPIFFE = true
	}

	if hasDNS && hasSPIFFE {
		if dnsID.AgentID != spiffeID.AgentID || dnsID.PartitionID != spiffeID.PartitionID {
			return PeerIdentity{}, ErrPeerIdentityConflict
		}
		dnsID.TrustDomain = spiffeID.TrustDomain
		return dnsID, nil
	}
	if hasSPIFFE {
		return spiffeID, nil
	}
	if hasDNS {
		return dnsID, nil
	}
	return PeerIdentity{}, ErrPeerIdentityInvalid
}

func parseServiceRadarDNSIdentity(raw string) (PeerIdentity, bool, error) {
	trimmed := strings.TrimSpace(raw)
	if !strings.HasSuffix(trimmed, serviceRadarDNSSuffix) {
		return PeerIdentity{}, false, nil
	}
	parts := strings.Split(trimmed, ".")
	if len(parts) != 3 || parts[2] != "serviceradar" {
		return PeerIdentity{}, false, fmt.Errorf("%w: malformed serviceradar DNS identity %q", ErrPeerIdentityInvalid, trimmed)
	}
	agentID := parts[0]
	partitionID := parts[1]
	if edgerecord.ValidateAuthenticatedPrincipal([]byte(agentID)) != nil ||
		edgerecord.ValidateAuthenticatedPrincipal([]byte(partitionID)) != nil {
		return PeerIdentity{}, false, fmt.Errorf("%w: invalid principal in DNS identity %q", ErrPeerIdentityInvalid, trimmed)
	}
	return PeerIdentity{
		AgentID:     agentID,
		PartitionID: partitionID,
	}, true, nil
}

func parseSPIFFEAgentURI(host, path string) (PeerIdentity, error) {
	trustDomain := strings.TrimSpace(host)
	if trustDomain == "" {
		return PeerIdentity{}, fmt.Errorf("%w: empty SPIFFE trust domain", ErrPeerIdentityInvalid)
	}
	trimmedPath := strings.TrimPrefix(path, "/")
	parts := strings.Split(trimmedPath, "/")
	if len(parts) != 3 || parts[0] != "agent" {
		return PeerIdentity{}, fmt.Errorf("%w: unexpected SPIFFE path %q", ErrPeerIdentityInvalid, path)
	}
	partitionID := parts[1]
	agentID := parts[2]
	if edgerecord.ValidateAuthenticatedPrincipal([]byte(agentID)) != nil ||
		edgerecord.ValidateAuthenticatedPrincipal([]byte(partitionID)) != nil {
		return PeerIdentity{}, fmt.Errorf("%w: invalid principal in SPIFFE URI", ErrPeerIdentityInvalid)
	}
	return PeerIdentity{
		AgentID:     agentID,
		PartitionID: partitionID,
		TrustDomain: trustDomain,
	}, nil
}
