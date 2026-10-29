package agent

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"net"
	"os"
	"slices"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

// pveNodeCertificateOU is the organizational unit Proxmox VE puts in the subject
// of each node's own certificate (pve-ssl.pem), which it generates per node with
// the node's own key. A custom or ACME pveproxy-ssl.pem does not carry it, and
// may be one wildcard certificate shared by many nodes, so it is never reported.
const pveNodeCertificateOU = "PVE Cluster Node"

// pveCertificateProbe reads the certificate pveproxy presents on the agent's own
// host. It needs no privilege: the agent cannot read /etc/pve (root:www-data), so
// it opens one TLS handshake to the local pveproxy and sends no request.
type pveCertificateProbe struct {
	configDir string
	address   string
	port      uint32
	timeout   time.Duration
}

func defaultPVECertificateProbe() pveCertificateProbe {
	return pveCertificateProbe{
		configDir: "/etc/pve",
		address:   "127.0.0.1:8006",
		port:      8006,
		timeout:   2 * time.Second,
	}
}

func defaultHostTLSFingerprints() []*proto.HostTlsFingerprint {
	return defaultPVECertificateProbe().fingerprints()
}

// helloHostTLSFingerprints reports the host's certificates on both hello
// transports. A loop built without a probe reports none.
func (p *PushLoop) helloHostTLSFingerprints() []*proto.HostTlsFingerprint {
	if p.hostTLSFingerprints == nil {
		return nil
	}

	return p.hostTLSFingerprints()
}

// fingerprints returns the node certificate fingerprint on a Proxmox VE node, or
// nil anywhere else: when /etc/pve does not exist, when pveproxy does not answer
// within the timeout, or when the certificate it serves is not the node's own.
func (p pveCertificateProbe) fingerprints() []*proto.HostTlsFingerprint {
	if info, err := os.Stat(p.configDir); err != nil || !info.IsDir() {
		return nil
	}

	dialer := &net.Dialer{Timeout: p.timeout}
	// Verification is skipped for this handshake only: the node certificate is
	// signed by the cluster's own CA, which the agent does not trust. Nothing is
	// sent over the connection; only the presented certificate is read.
	conn, err := tls.DialWithDialer(dialer, "tcp", p.address, &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS12,
	})
	if err != nil {
		return nil
	}
	defer func() { _ = conn.Close() }()

	certificates := conn.ConnectionState().PeerCertificates
	if len(certificates) == 0 || !pveNodeCertificate(certificates[0]) {
		return nil
	}

	digest := sha256.Sum256(certificates[0].Raw)

	return []*proto.HostTlsFingerprint{{Port: p.port, Sha256: hex.EncodeToString(digest[:])}}
}

func pveNodeCertificate(certificate *x509.Certificate) bool {
	return slices.Contains(certificate.Subject.OrganizationalUnit, pveNodeCertificateOU)
}
