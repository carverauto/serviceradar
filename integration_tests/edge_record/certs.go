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

// Package verticalslice provides the harness for
// //integration_tests/edge_record:vertical_slice_test (task 0.12,
// openspec/changes/unify-sweep-results-proto).
//
// certs.go builds a disposable, synthetic mTLS PKI for one test run. Every
// value here is invented per AGENTS.md's hard rule against committing or
// reusing captured deployment data -- nothing here resolves to a real
// certificate, host, or identity.
package verticalslice

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"time"
)

// certValidity is deliberately short: this PKI is minted fresh for one test
// run and never persisted or reused across runs.
const certValidity = 24 * time.Hour

// CertSet is a self-contained synthetic PKI for one test run: one CA, one
// gateway server leaf (for the gRPC TLS listener), one valid agent client
// leaf (SPIFFE component_type=agent, used by the real go/cmd/agent process),
// and one mismatched client leaf (SPIFFE component_type=desktop, same
// partition/component-id scheme, used ONLY for task 0.12 Group A's
// mismatched-identity control -- same fixture record bytes, different
// signing identity, expected to be refused with permission_denied before
// any NATS publish).
//
// File names match
// ServiceRadarAgentGateway.Application.edge_server_ssl_opts!/0's
// convention (elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex:254-277):
// <Dir>/root.pem, <Dir>/gateway.pem, <Dir>/gateway-key.pem -- so Dir can be
// pointed at directly via GATEWAY_CERT_DIR.
type CertSet struct {
	Dir              string
	CACertPath       string
	GatewayCertPath  string
	GatewayKeyPath   string
	AgentCertPath    string
	AgentKeyPath     string
	MismatchCertPath string
	MismatchKeyPath  string

	PartitionID         string
	AgentComponentID    string
	MismatchComponentID string

	// GatewayServerName is the TLS server name clients verify the gateway
	// leaf against: "gateway.<PartitionID>.serviceradar".
	GatewayServerName string

	caCert *x509.Certificate
	caKey  *ecdsa.PrivateKey
}

// GenerateCertSet creates a fresh CA and the four leaf certificates described
// above under dir (created if needed), all ECDSA P-256. gatewayBindHost is
// the hostname/IP the gateway's gRPC TLS listener will present -- it is
// added as both a DNS and IP SAN (whichever applies) on the gateway leaf so
// a Go TLS client validates the server name correctly.
func GenerateCertSet(dir, gatewayBindHost string) (*CertSet, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("verticalslice: mkdir cert dir: %w", err)
	}

	caKey, caCert, caDER, err := generateCA()
	if err != nil {
		return nil, fmt.Errorf("verticalslice: generate CA: %w", err)
	}

	cs := &CertSet{
		Dir:                 dir,
		PartitionID:         "vslice-partition",
		AgentComponentID:    "vslice-agent-01",
		MismatchComponentID: "vslice-desktop-01",
		caCert:              caCert,
		caKey:               caKey,
	}

	cs.CACertPath = filepath.Join(dir, "root.pem")
	if err := writePEMFile(cs.CACertPath, "CERTIFICATE", caDER); err != nil {
		return nil, fmt.Errorf("verticalslice: write CA cert: %w", err)
	}

	// Gateway server leaf: no SPIFFE component identity is required (the
	// resolver only runs against CLIENT certs), but it does need SANs
	// covering GatewayServerName and gatewayBindHost so client-side TLS
	// server-name verification succeeds.
	cs.GatewayServerName = "gateway." + cs.PartitionID + ".serviceradar"
	cs.GatewayCertPath = filepath.Join(dir, "gateway.pem")
	cs.GatewayKeyPath = filepath.Join(dir, "gateway-key.pem")
	if err := cs.issueServerLeaf(cs.GatewayCertPath, cs.GatewayKeyPath, cs.GatewayServerName, gatewayBindHost); err != nil {
		return nil, fmt.Errorf("verticalslice: issue gateway leaf: %w", err)
	}

	cs.AgentCertPath = filepath.Join(dir, "agent.pem")
	cs.AgentKeyPath = filepath.Join(dir, "agent-key.pem")
	if err := cs.issueClientLeaf(cs.AgentCertPath, cs.AgentKeyPath, "agent", cs.AgentComponentID); err != nil {
		return nil, fmt.Errorf("verticalslice: issue agent leaf: %w", err)
	}

	cs.MismatchCertPath = filepath.Join(dir, "mismatch.pem")
	cs.MismatchKeyPath = filepath.Join(dir, "mismatch-key.pem")
	if err := cs.issueClientLeaf(cs.MismatchCertPath, cs.MismatchKeyPath, "desktop", cs.MismatchComponentID); err != nil {
		return nil, fmt.Errorf("verticalslice: issue mismatch leaf: %w", err)
	}

	return cs, nil
}

func generateCA() (*ecdsa.PrivateKey, *x509.Certificate, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, err
	}

	serial, err := randomSerial()
	if err != nil {
		return nil, nil, nil, err
	}

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "vertical-slice-test-root",
			Organization: []string{"ServiceRadar Vertical Slice Test (synthetic)"},
		},
		NotBefore:             time.Now().Add(-5 * time.Minute),
		NotAfter:              time.Now().Add(certValidity),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, nil, err
	}

	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, nil, err
	}

	return key, cert, der, nil
}

// issueServerLeaf issues a plain TLS server certificate (no SPIFFE component
// identity -- ComponentIdentityResolver never runs against the server cert).
func (c *CertSet) issueServerLeaf(certPath, keyPath, cn, bindHost string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	serial, err := randomSerial()
	if err != nil {
		return err
	}

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-5 * time.Minute),
		NotAfter:     time.Now().Add(certValidity),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		// Go verifies the server name against SANs only, never the CN.
		DNSNames: []string{cn, "localhost"},
	}

	if ip := net.ParseIP(bindHost); ip != nil {
		tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
	} else if bindHost != "" {
		tmpl.DNSNames = append(tmpl.DNSNames, bindHost)
	}
	tmpl.IPAddresses = append(tmpl.IPAddresses, net.ParseIP("127.0.0.1"))

	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.caCert, &key.PublicKey, c.caKey)
	if err != nil {
		return err
	}

	if err := writePEMFile(certPath, "CERTIFICATE", der); err != nil {
		return err
	}
	return writeECKeyPEMFile(keyPath, key)
}

// issueClientLeaf issues a client certificate carrying the CN and SPIFFE URI
// SAN ComponentIdentityResolver.resolve_from_cert/1 expects
// (elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/component_identity_resolver.ex):
//   - CN:  "<componentID>.<c.PartitionID>.serviceradar"
//   - SAN: URI "spiffe://serviceradar.local/<componentType>/<c.PartitionID>/<componentID>"
//
// componentType "agent" resolves to :agent (valid identity); any other value
// (e.g. "desktop") resolves component_type to nil, which fails
// require_agent_identity!/1 with a permission_denied gRPC error -- the
// mismatched-identity control task 0.12 Group A requires.
func (c *CertSet) issueClientLeaf(certPath, keyPath, componentType, componentID string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	serial, err := randomSerial()
	if err != nil {
		return err
	}

	cn := fmt.Sprintf("%s.%s.serviceradar", componentID, c.PartitionID)
	spiffeURI := &url.URL{
		Scheme: "spiffe",
		Host:   "serviceradar.local",
		Path:   fmt.Sprintf("/%s/%s/%s", componentType, c.PartitionID, componentID),
	}

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-5 * time.Minute),
		NotAfter:     time.Now().Add(certValidity),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		URIs:         []*url.URL{spiffeURI},
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, c.caCert, &key.PublicKey, c.caKey)
	if err != nil {
		return err
	}

	if err := writePEMFile(certPath, "CERTIFICATE", der); err != nil {
		return err
	}
	return writeECKeyPEMFile(keyPath, key)
}

// AgentTLSConfig returns a *tls.Config for a gRPC client connecting as the
// valid agent identity (client cert = AgentCertPath, root CA = CACertPath,
// ServerName = gatewayBindHost).
func (c *CertSet) AgentTLSConfig(gatewayBindHost string) (*tls.Config, error) {
	return c.clientTLSConfig(c.AgentCertPath, c.AgentKeyPath, gatewayBindHost)
}

// MismatchTLSConfig is the same, but presents the mismatched-identity client
// certificate instead.
func (c *CertSet) MismatchTLSConfig(gatewayBindHost string) (*tls.Config, error) {
	return c.clientTLSConfig(c.MismatchCertPath, c.MismatchKeyPath, gatewayBindHost)
}

func (c *CertSet) clientTLSConfig(certPath, keyPath, serverName string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: load client keypair: %w", err)
	}

	caPEM, err := os.ReadFile(c.CACertPath)
	if err != nil {
		return nil, fmt.Errorf("verticalslice: read CA cert: %w", err)
	}

	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("verticalslice: failed to parse CA cert %s", c.CACertPath)
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      pool,
		ServerName:   serverName,
		MinVersion:   tls.VersionTLS12,
	}, nil
}

// readPEMCert reads and parses a single PEM-encoded certificate file.
func readPEMCert(path string) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("verticalslice: no PEM block found in %s", path)
	}
	return x509.ParseCertificate(block.Bytes)
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	return rand.Int(rand.Reader, limit)
}

func writePEMFile(path, blockType string, der []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	return pem.Encode(f, &pem.Block{Type: blockType, Bytes: der})
}

func writeECKeyPEMFile(path string, key *ecdsa.PrivateKey) error {
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	return pem.Encode(f, &pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
}
