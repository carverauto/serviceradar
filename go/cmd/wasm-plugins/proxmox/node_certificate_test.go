package main

import (
	"strings"
	"testing"
)

// A certificates/info response in the shape Proxmox VE returns: the node's own
// pve-ssl.pem plus an installed custom pveproxy-ssl.pem. Values are invented.
const certificatesInfoBody = `{"data":[
 {"filename":"pveproxy-ssl.pem","fingerprint":"11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00","subject":"/CN=*.example.com"},
 {"filename":"pve-ssl.pem","fingerprint":"AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89","subject":"/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=node-a.example.com"}
]}`

func TestNodeCertificateFingerprintUsesOnlyTheNodeCertificate(t *testing.T) {
	var response proxmoxCertificatesResponse
	if err := decodeProxmoxJSON([]byte(certificatesInfoBody), &response); err != nil {
		t.Fatalf("decode: %v", err)
	}

	got := nodeCertificateFingerprint(response.Data)
	want := "pve:sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	if got != want {
		t.Fatalf("fingerprint = %q, want %q (pve-ssl.pem, never the shareable pveproxy-ssl.pem)", got, want)
	}
}

func TestNodeCertificateFingerprintIgnoresCustomCertificatesAndBadValues(t *testing.T) {
	cases := map[string][]proxmoxCertificateInfo{
		"only a custom certificate": {
			{Filename: "pveproxy-ssl.pem", Fingerprint: strings.Repeat("AA:", 31) + "AA"},
		},
		"truncated fingerprint": {
			{Filename: "pve-ssl.pem", Fingerprint: "AB:CD:EF"},
		},
		"not hex": {
			{Filename: "pve-ssl.pem", Fingerprint: strings.Repeat("ZZ:", 31) + "ZZ"},
		},
		"no certificates": nil,
	}

	for name, certificates := range cases {
		if got := nodeCertificateFingerprint(certificates); got != "" {
			t.Fatalf("%s: fingerprint = %q, want empty", name, got)
		}
	}
}

func TestDiscoveredNodeAndDetailsCarryTheCertificateFingerprint(t *testing.T) {
	fingerprint := "pve:sha256:" + strings.Repeat("0f", 32)

	metadata := withNodeCertificateFingerprint(nil, fingerprint)
	if metadata["tls_certificate_fingerprint"] != fingerprint {
		t.Fatalf("discovery metadata = %#v, want the node certificate fingerprint", metadata)
	}

	if unchanged := withNodeCertificateFingerprint(nil, ""); unchanged != nil {
		t.Fatalf("metadata without a fingerprint = %#v, want nil", unchanged)
	}

	var b strings.Builder
	appendNodeJSON(&b, proxmoxNode{Node: "node-a", TLSCertificateFingerprint: fingerprint})
	if !strings.Contains(b.String(), `"tls_certificate_fingerprint":"`+fingerprint+`"`) {
		t.Fatalf("node details = %s, want the certificate fingerprint", b.String())
	}
}
