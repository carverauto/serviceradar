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

// Package tenant provides multi-tenant identity extraction and validation.
//
// Tenant identity is extracted from mTLS certificate Common Names (CN).
// The CN format is: <component_id>.<partition_id>.<tenant_slug>.serviceradar
//
// Example: agent-001.partition-1.acme-corp.serviceradar
//
// This package supports:
//   - Parsing tenant info from certificate CN
//   - Extracting tenant from gRPC peer certificates
//   - NATS channel prefixing for tenant isolation
//   - Context-based tenant propagation
package tenant

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"strings"

	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/peer"
)

// ctxKey is the type for context keys in this package.
type ctxKey string

// tenantCtxKey is the context key for storing tenant info.
const tenantCtxKey ctxKey = "tenant"

const (
	// CNSuffix is the expected suffix for ServiceRadar certificate CNs.
	CNSuffix = "serviceradar"

	// CNParts is the expected number of parts in a valid CN.
	// Format: <component_id>.<partition_id>.<tenant_slug>.serviceradar
	CNParts = 4
)

var (
	// ErrInvalidCNFormat indicates the certificate CN doesn't match expected format.
	ErrInvalidCNFormat = errors.New("invalid certificate CN format")

	// ErrNoPeerCert indicates no peer certificate was found in the context.
	ErrNoPeerCert = errors.New("no peer certificate in context")

	// ErrNoPeerInfo indicates no peer info was found in the context.
	ErrNoPeerInfo = errors.New("no peer info in context")

	// ErrNoTLSInfo indicates no TLS info was found in peer credentials.
	ErrNoTLSInfo = errors.New("no TLS info in peer credentials")

	// ErrNoTenantInContext indicates no tenant info was found in the context.
	ErrNoTenantInContext = errors.New("no tenant info in context")
)

// WithContext returns a new context with the tenant info attached.
func WithContext(ctx context.Context, info *Info) context.Context {
	return context.WithValue(ctx, tenantCtxKey, info)
}

// FromContext extracts tenant info from a context.
// Returns ErrNoTenantInContext if no tenant info is present.
func FromContext(ctx context.Context) (*Info, error) {
	info, ok := ctx.Value(tenantCtxKey).(*Info)
	if !ok || info == nil {
		return nil, ErrNoTenantInContext
	}
	return info, nil
}

// MustFromContext extracts tenant info from a context or panics.
// Use only when tenant presence is guaranteed (e.g., after middleware validation).
func MustFromContext(ctx context.Context) *Info {
	info, err := FromContext(ctx)
	if err != nil {
		panic(err)
	}
	return info
}

// SlugFromContext extracts just the tenant slug from a context.
// Returns empty string if no tenant info is present.
func SlugFromContext(ctx context.Context) string {
	info, err := FromContext(ctx)
	if err != nil {
		return ""
	}
	return info.TenantSlug
}

// Info contains tenant identity information extracted from a certificate.
type Info struct {
	// TenantSlug is the tenant identifier (e.g., "acme-corp").
	TenantSlug string `json:"tenant_slug"`

	// PartitionID is the partition/location identifier (e.g., "partition-1").
	PartitionID string `json:"partition_id"`

	// ComponentID is the component identifier (e.g., "agent-001").
	ComponentID string `json:"component_id"`
}

// String returns a human-readable representation of the tenant info.
func (i Info) String() string {
	return fmt.Sprintf("%s/%s/%s", i.TenantSlug, i.PartitionID, i.ComponentID)
}

// CN returns the full certificate CN for this tenant info.
func (i Info) CN() string {
	return fmt.Sprintf("%s.%s.%s.%s", i.ComponentID, i.PartitionID, i.TenantSlug, CNSuffix)
}

// NATSPrefix returns the NATS channel prefix for this tenant.
// Format: <tenant_slug>.
func (i Info) NATSPrefix() string {
	return i.TenantSlug + "."
}

// PrefixChannel returns a NATS channel name prefixed with the tenant slug.
// Example: "events.poller.health" -> "acme-corp.events.poller.health"
func (i Info) PrefixChannel(channel string) string {
	return i.TenantSlug + "." + channel
}

// PrefixChannelWithSlug returns a NATS channel name prefixed with the given tenant slug.
// This is a standalone function for use when only the slug is available.
// Example: PrefixChannelWithSlug("acme-corp", "events.poller.health") -> "acme-corp.events.poller.health"
func PrefixChannelWithSlug(tenantSlug, channel string) string {
	if tenantSlug == "" {
		return channel
	}
	return tenantSlug + "." + channel
}

// PrefixChannelFromContext prefixes a channel using tenant info from the context.
// Returns the original channel if no tenant is in context.
func PrefixChannelFromContext(ctx context.Context, channel string) string {
	info, err := FromContext(ctx)
	if err != nil {
		return channel
	}
	return info.PrefixChannel(channel)
}

// ParseCN extracts tenant information from a certificate Common Name.
//
// Expected format: <component_id>.<partition_id>.<tenant_slug>.serviceradar
// Example: agent-001.partition-1.acme-corp.serviceradar
//
// Returns ErrInvalidCNFormat if the CN doesn't match the expected format.
func ParseCN(cn string) (*Info, error) {
	parts := strings.Split(cn, ".")
	if len(parts) != CNParts {
		return nil, fmt.Errorf("%w: expected %d parts, got %d in %q",
			ErrInvalidCNFormat, CNParts, len(parts), cn)
	}

	if parts[3] != CNSuffix {
		return nil, fmt.Errorf("%w: expected suffix %q, got %q in %q",
			ErrInvalidCNFormat, CNSuffix, parts[3], cn)
	}

	return &Info{
		ComponentID: parts[0],
		PartitionID: parts[1],
		TenantSlug:  parts[2],
	}, nil
}

// FromCertificate extracts tenant information from an X.509 certificate.
func FromCertificate(cert *x509.Certificate) (*Info, error) {
	if cert == nil {
		return nil, ErrNoPeerCert
	}

	return ParseCN(cert.Subject.CommonName)
}

// FromTLSState extracts tenant information from a TLS connection state.
func FromTLSState(state *tls.ConnectionState) (*Info, error) {
	if state == nil || len(state.PeerCertificates) == 0 {
		return nil, ErrNoPeerCert
	}

	return FromCertificate(state.PeerCertificates[0])
}

// FromGRPCContext extracts tenant information from a gRPC context.
// This is useful in gRPC server handlers to identify the calling tenant.
func FromGRPCContext(ctx context.Context) (*Info, error) {
	p, ok := peer.FromContext(ctx)
	if !ok {
		return nil, ErrNoPeerInfo
	}

	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok {
		return nil, ErrNoTLSInfo
	}

	return FromTLSState(&tlsInfo.State)
}

// FromCertFile extracts tenant information from a PEM certificate file.
// This is useful for extracting tenant identity at agent startup.
func FromCertFile(certPath string) (*Info, error) {
	certPEM, err := os.ReadFile(certPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read certificate file: %w", err)
	}

	return FromPEM(certPEM)
}

// FromPEM extracts tenant information from PEM-encoded certificate data.
func FromPEM(certPEM []byte) (*Info, error) {
	// Parse the certificate
	cert, err := x509.ParseCertificate(decodePEM(certPEM))
	if err != nil {
		// Try parsing as a certificate chain
		certs, parseErr := x509.ParseCertificates(decodePEM(certPEM))
		if parseErr != nil || len(certs) == 0 {
			return nil, fmt.Errorf("failed to parse certificate: %w", err)
		}
		cert = certs[0]
	}

	return FromCertificate(cert)
}

// decodePEM extracts the DER bytes from PEM-encoded data.
func decodePEM(pemData []byte) []byte {
	// Simple PEM decoder - find the base64 content between headers
	const beginCert = "-----BEGIN CERTIFICATE-----"
	const endCert = "-----END CERTIFICATE-----"

	start := strings.Index(string(pemData), beginCert)
	if start == -1 {
		return pemData // Not PEM, return as-is (might be DER)
	}

	end := strings.Index(string(pemData), endCert)
	if end == -1 {
		return pemData
	}

	// Extract base64 content
	b64 := strings.TrimSpace(string(pemData[start+len(beginCert) : end]))
	b64 = strings.ReplaceAll(b64, "\n", "")
	b64 = strings.ReplaceAll(b64, "\r", "")

	// Decode base64
	decoded := make([]byte, len(b64))
	n := decodeBase64(decoded, []byte(b64))

	return decoded[:n]
}

// decodeBase64 is a simple base64 decoder.
func decodeBase64(dst, src []byte) int {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

	// Build decode table
	decodeTable := make([]int, 256)
	for i := range decodeTable {
		decodeTable[i] = -1
	}
	for i, c := range alphabet {
		decodeTable[c] = i
	}
	decodeTable['='] = 0

	n := 0
	buf := 0
	bufLen := 0

	for _, c := range src {
		val := decodeTable[c]
		if val == -1 {
			continue // Skip whitespace/invalid chars
		}

		buf = (buf << 6) | val
		bufLen += 6

		if bufLen >= 8 {
			bufLen -= 8
			dst[n] = byte(buf >> bufLen)
			n++
			buf &= (1 << bufLen) - 1
		}
	}

	return n
}
