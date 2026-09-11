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

package verticalslice

import (
	"crypto/x509"
	"fmt"
	"strings"
	"testing"
)

// TestGenerateCertSetSPIFFEShape proves the generated leaf certificates
// round-trip through Go's own x509 parser with exactly the CN and SPIFFE URI
// SAN shape ComponentIdentityResolver.resolve_from_cert/1 requires:
//   - CN:  "<componentID>.<partitionID>.serviceradar"
//   - SAN: URI "spiffe://serviceradar.local/<componentType>/<partitionID>/<componentID>"
func TestGenerateCertSetSPIFFEShape(t *testing.T) {
	dir := t.TempDir()

	cs, err := GenerateCertSet(dir, "127.0.0.1")
	if err != nil {
		t.Fatalf("GenerateCertSet: %v", err)
	}

	checkLeaf(t, cs.AgentCertPath, "agent", cs.PartitionID, cs.AgentComponentID)
	checkLeaf(t, cs.MismatchCertPath, "desktop", cs.PartitionID, cs.MismatchComponentID)

	// Gateway leaf must chain to the same CA and present a usable server name.
	gwCert := loadCert(t, cs.GatewayCertPath)
	roots := x509.NewCertPool()
	roots.AddCert(loadCert(t, cs.CACertPath))
	for _, name := range []string{"localhost", cs.GatewayServerName} {
		if _, err := gwCert.Verify(x509.VerifyOptions{
			Roots:     roots,
			DNSName:   name,
			KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		}); err != nil {
			t.Fatalf("gateway leaf does not verify against CA for DNSName %s: %v", name, err)
		}
	}

	// Client leaves must also chain to the CA (mirrors what the gRPC TLS
	// listener's verify_peer will do before ComponentIdentityResolver ever runs).
	agentCert := loadCert(t, cs.AgentCertPath)
	if _, err := agentCert.Verify(x509.VerifyOptions{
		Roots:     roots,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}); err != nil {
		t.Fatalf("agent leaf does not verify against CA: %v", err)
	}

	if _, err := cs.AgentTLSConfig("127.0.0.1"); err != nil {
		t.Fatalf("AgentTLSConfig: %v", err)
	}
	if _, err := cs.MismatchTLSConfig("127.0.0.1"); err != nil {
		t.Fatalf("MismatchTLSConfig: %v", err)
	}
}

func checkLeaf(t *testing.T, path, wantComponentType, wantPartition, wantComponentID string) {
	t.Helper()

	cert := loadCert(t, path)

	wantCN := fmt.Sprintf("%s.%s.serviceradar", wantComponentID, wantPartition)
	if cert.Subject.CommonName != wantCN {
		t.Fatalf("%s: CN = %q, want %q", path, cert.Subject.CommonName, wantCN)
	}

	wantURI := fmt.Sprintf("spiffe://serviceradar.local/%s/%s/%s", wantComponentType, wantPartition, wantComponentID)
	found := false
	for _, u := range cert.URIs {
		if u.String() == wantURI {
			found = true
			break
		}
	}
	if !found {
		got := make([]string, 0, len(cert.URIs))
		for _, u := range cert.URIs {
			got = append(got, u.String())
		}
		t.Fatalf("%s: URI SANs = %v, want to contain %q", path, strings.Join(got, ","), wantURI)
	}
}

func loadCert(t *testing.T, path string) *x509.Certificate {
	t.Helper()

	pemBytes, err := readPEMCert(path)
	if err != nil {
		t.Fatalf("read cert %s: %v", path, err)
	}
	return pemBytes
}
