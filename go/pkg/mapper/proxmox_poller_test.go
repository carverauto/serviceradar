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

package mapper

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

func TestQueryProxmoxDevices(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "PVEAPIToken=svc@pve!codex=secret-token", r.Header.Get("Authorization"))
		w.Header().Set("Content-Type", "application/json")

		switch r.URL.Path {
		case "/api2/json/nodes":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{"node": "tonka01"},
				},
			})
		case "/api2/json/cluster/resources":
			assert.Equal(t, "vm", r.URL.Query().Get("type"))
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{
						"type":   "qemu",
						"vmid":   197,
						"name":   "vJunos-Lab-01.lab.carverauto.dev",
						"node":   "tonka01",
						"status": "running",
					},
					{
						"type":     "qemu",
						"vmid":     900,
						"name":     "tmpl-router",
						"node":     "tonka01",
						"status":   "stopped",
						"template": 1,
					},
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 30 * time.Second,
			ProxmoxAPIs: []ProxmoxAPIConfig{
				{
					BaseURL:     server.URL,
					TokenID:     "svc@pve!codex",
					TokenSecret: "secret-token",
					Name:        "tonka01-pve",
				},
			},
		},
		logger: logger.NewTestLogger(),
	}

	job := &DiscoveryJob{
		ID: "test-job",
		Params: &DiscoveryParams{
			Options: map[string]string{
				"proxmox_api_names": "tonka01-pve",
			},
		},
	}

	devices, links, err := engine.queryProxmoxDevices(context.Background(), job)
	require.NoError(t, err)
	require.Len(t, devices, 2)
	require.Len(t, links, 1)

	assert.Equal(t, "tonka01", devices[0].Hostname)
	assert.Equal(t, GenerateDeviceIDFromIP("127.0.0.1"), devices[0].DeviceID)
	assert.Equal(t, "hypervisor", devices[0].Metadata["device_role"])

	assert.Equal(t, "vJunos-Lab-01.lab.carverauto.dev", devices[1].Hostname)
	assert.Equal(t, "provisional", devices[1].Metadata["identity_state"])
	assert.Equal(t, "false", devices[1].Metadata["snmp_target_eligible"])

	assert.Equal(t, "Proxmox-API", links[0].Protocol)
	assert.Equal(t, "hosted-guests", links[0].LocalIfName)
	assert.Equal(t, "vJunos-Lab-01.lab.carverauto.dev", links[0].NeighborSystemName)
	require.NotNil(t, links[0].NeighborIdentity)
	assert.Equal(t, devices[1].DeviceID, links[0].NeighborIdentity.DeviceID)
	assert.Equal(t, "proxmox-api", links[0].Metadata["source"])
}

func TestProxmoxCandidateFingerprintFromHTML(t *testing.T) {
	html := `<!DOCTYPE html><html><head><title>pve01 - Proxmox Virtual Environment</title></head><body></body></html>`

	node, ok := proxmoxFingerprintFromHTML(html)

	require.True(t, ok)
	assert.Equal(t, "pve01", node)
}

func TestProxmoxCandidateFingerprintRejectsGenericHTTPS(t *testing.T) {
	node, ok := proxmoxFingerprintFromHTML(`<!DOCTYPE html><title>router</title>`)

	require.False(t, ok)
	assert.Empty(t, node)
}

func TestProxmoxCandidateBaseURL(t *testing.T) {
	assert.Equal(t, "https://192.0.2.10:8006", proxmoxCandidateBaseURL("192.0.2.10"))
	assert.Equal(t, "https://192.0.2.10:8006", proxmoxCandidateBaseURL("https://192.0.2.10:8006/"))
	assert.Equal(t, "https://[2001:db8::10]:8006", proxmoxCandidateBaseURL("[2001:db8::10]:8006"))
}

func TestBuildProxmoxCandidateDevice(t *testing.T) {
	device := buildProxmoxCandidateDevice("192.0.2.10", "pve01")

	require.NotNil(t, device)
	assert.Equal(t, GenerateDeviceIDFromIP("192.0.2.10"), device.DeviceID)
	assert.Equal(t, "192.0.2.10", device.IP)
	assert.Equal(t, "pve01", device.Hostname)
	assert.Equal(t, "proxmox-candidate", device.Metadata["source"])
	assert.Equal(t, "true", device.Metadata["proxmox_candidate"])
	assert.Equal(t, "false", device.Metadata["snmp_target_eligible"])
}

func TestProxmoxCandidateSeedsPutKnownDeviceIPsFirstAndListEachOnce(t *testing.T) {
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{IP: "192.0.2.10"},
				{IP: ""},
				nil,
				{IP: "192.0.2.10"},
				{IP: "192.0.2.11"},
			},
		},
	}

	assert.Equal(t,
		[]string{"192.0.2.10", "192.0.2.11", "192.0.2.20"},
		proxmoxCandidateSeeds(job, []string{"192.0.2.20", " 192.0.2.10 ", ""}))
}

func TestGroupProxmoxCandidatesByNodeMergesOneNodesAddresses(t *testing.T) {
	candidate := func(ip, title, sans string) *DiscoveredDevice {
		device := buildProxmoxCandidateDevice(ip, title)
		if sans != "" {
			device.Metadata["proxmox_tls_sans_recorded"] = stringTrueValue
			device.Metadata["proxmox_tls_san_ips"] = sans
		}
		return device
	}

	unknown := func(string) bool { return false }

	grouped := groupProxmoxCandidatesByNode([]*DiscoveredDevice{
		// One node at two addresses; the certificate lists the second.
		candidate("198.51.100.20", "pve01", "127.0.0.1,::1,192.0.2.20"),
		candidate("192.0.2.20", "pve01", "127.0.0.1,::1,192.0.2.20"),
		// Another node with the same name presents a different certificate.
		candidate("192.0.2.30", "pve01", "127.0.0.1,::1,192.0.2.30"),
		// Without recorded SANs a candidate is not grouped.
		candidate("192.0.2.40", "pve01", ""),
	}, unknown)

	require.Len(t, grouped, 3)
	assert.Equal(t, "192.0.2.20", grouped[1].IP)
	assert.Equal(t, GenerateDeviceIDFromIP("192.0.2.20"), grouped[1].DeviceID)
	assert.Equal(t, "1", grouped[1].Metadata["alt_ip:198.51.100.20"])
	assert.Equal(t, "192.0.2.30", grouped[2].IP)
	assert.NotContains(t, grouped[2].Metadata, "alt_ip:198.51.100.20")
	assert.Equal(t, "192.0.2.40", grouped[0].IP)
}

func TestProxmoxNodeCandidatesFoldIntoOneJobDevice(t *testing.T) {
	nodeCandidates := func() []*DiscoveredDevice {
		first := buildProxmoxCandidateDevice("198.51.100.21", "pve02")
		second := buildProxmoxCandidateDevice("192.0.2.21", "pve02")
		for _, device := range []*DiscoveredDevice{first, second} {
			device.Metadata["proxmox_tls_sans_recorded"] = stringTrueValue
			device.Metadata["proxmox_tls_san_ips"] = "127.0.0.1,::1,192.0.2.21"
		}
		return []*DiscoveredDevice{first, second}
	}

	newJob := func(devices ...*DiscoveredDevice) *DiscoveryJob {
		job := &DiscoveryJob{
			ID:        "job-1",
			Results:   &DiscoveryResults{},
			deviceMap: map[string]*DeviceInterfaceMap{},
		}
		for _, device := range devices {
			job.Results.Devices = append(job.Results.Devices, device)
			job.deviceMap[device.DeviceID] = &DeviceInterfaceMap{
				DeviceID: device.DeviceID,
				IPs:      map[string]struct{}{device.IP: {}},
				MACs:     map[string]struct{}{device.MAC: {}},
			}
		}
		return job
	}

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	t.Run("a node the job has not identified becomes one device", func(t *testing.T) {
		job := newJob()

		engine.addProxmoxCandidatesUnlocked(job, nodeCandidates())

		require.Len(t, job.Results.Devices, 1)
		assert.Equal(t, "192.0.2.21", job.Results.Devices[0].IP)
		assert.Equal(t, "1", job.Results.Devices[0].Metadata["alt_ip:198.51.100.21"])
	})

	t.Run("a node the job holds at an address the certificate omits keeps its device", func(t *testing.T) {
		snmpNode := &DiscoveredDevice{
			DeviceID: "mac-020000000021",
			IP:       "198.51.100.21",
			MAC:      "02:00:00:00:00:21",
			Hostname: "pve02",
			Metadata: map[string]string{"source": "snmp"},
		}
		job := newJob(snmpNode)

		engine.addProxmoxCandidatesUnlocked(job, nodeCandidates())

		require.Len(t, job.Results.Devices, 1)
		assert.Equal(t, "mac-020000000021", job.Results.Devices[0].DeviceID)
		assert.Equal(t, "198.51.100.21", job.Results.Devices[0].IP)
		assert.Equal(t, "true", job.Results.Devices[0].Metadata["proxmox_candidate"])
		assert.Equal(t, "1", job.Results.Devices[0].Metadata["alt_ip:192.0.2.21"])
	})
}

func TestApplyJobOptionsMetadataSkipsProxmoxCandidateProbeOption(t *testing.T) {
	job := &DiscoveryJob{
		Params: &DiscoveryParams{
			Options: map[string]string{
				"mapper_job_name":           "tonka01",
				proxmoxCandidateProbeOption: "true",
			},
		},
	}
	metadata := map[string]string{}

	applyJobOptionsMetadata(job, metadata)

	assert.Equal(t, "tonka01", metadata["mapper_job_name"])
	assert.NotContains(t, metadata, proxmoxCandidateProbeOption)
}

func TestProbeProxmoxCandidateRecordsCertificateSANs(t *testing.T) {
	// httptest's certificate is valid for 127.0.0.1, ::1, example.com and *.example.com.
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("<html><head><title>pve01 - Proxmox Virtual Environment</title></head></html>"))
	}))
	defer server.Close()

	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}
	client := server.Client()

	device, err := engine.probeProxmoxCandidate(context.Background(), client, server.URL)
	require.NoError(t, err)

	assert.Equal(t, "true", device.Metadata["proxmox_tls_sans_recorded"])
	assert.Equal(t, "127.0.0.1,::1", device.Metadata["proxmox_tls_san_ips"])
	assert.Equal(t, "example.com,*.example.com", device.Metadata["proxmox_tls_san_dns"])
}

// TestRunDiscoveryJobProbesProxmoxAfterIdentity drives a real discovery engine
// at disposable TLS listeners. One node answers on two addresses and another
// node reuses the same web title with a different certificate. A page that is
// not the PVE UI is also listening. The job must publish one device per node,
// and the fingerprint must land after identity collection.
func TestRunDiscoveryJobProbesProxmoxAfterIdentity(t *testing.T) {
	hits := newPVEHits()
	shared := testPVECertificate(t, net.ParseIP("127.0.0.1"), net.ParseIP("127.0.0.2"))
	other := testPVECertificate(t, net.ParseIP("127.0.0.3"))

	servePVE(t, "127.0.0.1:8006", pvePage("pve01"), shared, hits)
	servePVE(t, "127.0.0.2:8006", pvePage("pve01"), shared, hits)
	servePVE(t, "127.0.0.3:8006", pvePage("pve01"), other, hits)
	servePVE(t, "127.0.0.4:8006", "<html><head><title>router</title></head></html>", testPVECertificate(t, net.ParseIP("127.0.0.4")), hits)

	engine := newTestDiscoveryEngine(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	require.NoError(t, engine.Start(ctx))
	t.Cleanup(func() {
		stopCtx, stopCancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer stopCancel()
		require.NoError(t, engine.Stop(stopCtx))
	})

	params := &DiscoveryParams{
		Seeds: []string{"127.0.0.1", "127.0.0.2", "127.0.0.3", "127.0.0.4"},
		Type:  DiscoveryTypeBasic,
		Mode:  "api",
		Options: map[string]string{
			proxmoxCandidateProbeOption: "true",
		},
	}
	discoveryID, err := engine.StartDiscovery(ctx, params)
	require.NoError(t, err)

	results := waitForDiscoveryResults(t, engine, discoveryID)
	logDiscoveredDevices(t, results.Devices)

	require.Len(t, results.Devices, 2)
	primary := deviceByIP(results.Devices, "127.0.0.1")
	separate := deviceByIP(results.Devices, "127.0.0.3")
	require.NotNil(t, primary)
	require.NotNil(t, separate)
	assert.Equal(t, "1", primary.Metadata["alt_ip:127.0.0.2"])
	assert.Equal(t, "true", primary.Metadata["proxmox_candidate"])
	assert.Equal(t, "pve01", primary.Hostname)
	assert.NotContains(t, primary.Metadata, "alt_ip:127.0.0.3")
	assert.NotContains(t, separate.Metadata, "alt_ip:127.0.0.1")
	assert.NotContains(t, separate.Metadata, "alt_ip:127.0.0.2")
	assert.Nil(t, deviceByIP(results.Devices, "127.0.0.2"))
	assert.Nil(t, deviceByIP(results.Devices, "127.0.0.4"))

	firstHit, routerHits := hits.snapshot("127.0.0.1:8006", "127.0.0.4:8006")
	require.False(t, firstHit.IsZero(), "node was not fingerprinted")
	assert.Equal(t, 1, routerHits)

	identityDone, enrichDone := stageTimes(results.Contract.StageTransitions)
	require.False(t, identityDone.IsZero())
	require.False(t, enrichDone.IsZero())
	assert.False(t, firstHit.Before(identityDone), "fingerprint %#v ran before identity completed at %#v", firstHit, identityDone)
	assert.False(t, enrichDone.Before(firstHit), "fingerprint %#v ran after enrichment completed at %#v", firstHit, enrichDone)

	_, before := hits.snapshot("127.0.0.1:8006", "127.0.0.1:8006")
	offID, err := engine.StartDiscovery(ctx, &DiscoveryParams{
		Seeds: []string{"127.0.0.1", "127.0.0.2"},
		Type:  DiscoveryTypeBasic,
		Mode:  "api",
		Options: map[string]string{
			proxmoxCandidateProbeOption: "false",
		},
	})
	require.NoError(t, err)
	offResults := waitForDiscoveryResults(t, engine, offID)
	assert.Empty(t, offResults.Devices)
	_, after := hits.snapshot("127.0.0.1:8006", "127.0.0.1:8006")
	assert.Equal(t, before, after, "disabled probe still requested the PVE UI")
}

// TestProxmoxCandidateAtKnownAlternateIPFoldsOntoSNMPDevice probes two real
// listeners for one node. The certificate lists only the second address. The
// job already holds the node at a third address and records the first as an
// alternate IP. The published result is that one SNMP device.
func TestProxmoxCandidateAtKnownAlternateIPFoldsOntoSNMPDevice(t *testing.T) {
	hits := newPVEHits()
	// The certificate omits 127.0.0.1, the address the job already stored.
	cert := testPVECertificate(t, net.ParseIP("127.0.0.2"))
	servePVE(t, "127.0.0.1:8006", pvePage("pve02"), cert, hits)
	servePVE(t, "127.0.0.2:8006", pvePage("pve02"), cert, hits)

	snmpNode := &DiscoveredDevice{
		DeviceID: "mac-020000000021",
		IP:       "192.0.2.50",
		MAC:      "02:00:00:00:00:21",
		Hostname: "pve02",
		Metadata: map[string]string{
			"source":           "snmp",
			"alt_ip:127.0.0.1": "1",
		},
	}
	job := &DiscoveryJob{
		ID: "job-alt-ip",
		Params: &DiscoveryParams{
			Options: map[string]string{proxmoxCandidateProbeOption: "true"},
		},
		Results: &DiscoveryResults{Devices: []*DiscoveredDevice{snmpNode}},
		deviceMap: map[string]*DeviceInterfaceMap{
			snmpNode.DeviceID: {
				DeviceID: snmpNode.DeviceID,
				IPs:      map[string]struct{}{snmpNode.IP: {}, "127.0.0.1": {}},
				MACs:     map[string]struct{}{snmpNode.MAC: {}},
			},
		},
	}
	engine := &DiscoveryEngine{
		config: &Config{Timeout: 300 * time.Millisecond},
		logger: logger.NewTestLogger(),
	}

	engine.probeProxmoxCandidatesAfterIdentity(context.Background(), job, []string{"127.0.0.2", "127.0.0.1"})

	logDiscoveredDevices(t, job.Results.Devices)
	require.Len(t, job.Results.Devices, 1)
	got := job.Results.Devices[0]
	assert.Equal(t, "mac-020000000021", got.DeviceID)
	assert.Equal(t, "192.0.2.50", got.IP)
	assert.Equal(t, "true", got.Metadata["proxmox_candidate"])
	assert.Equal(t, "1", got.Metadata["alt_ip:127.0.0.1"])
	assert.Equal(t, "1", got.Metadata["alt_ip:127.0.0.2"])
}

// TestKnownProxmoxDeviceIsFingerprintedBeforeAnUnreachableSeed gives the probe
// a deadline that a silent TCP peer can use up. The device the job already
// holds must still be fingerprinted.
func TestKnownProxmoxDeviceIsFingerprintedBeforeAnUnreachableSeed(t *testing.T) {
	hits := newPVEHits()
	servePVE(t, "127.0.0.2:8006", pvePage("pve03"), testPVECertificate(t, net.ParseIP("127.0.0.2")), hits)
	serveSilentTCP(t, "127.0.0.1:8006")

	known := &DiscoveredDevice{
		DeviceID: "mac-020000000022",
		IP:       "127.0.0.2",
		MAC:      "02:00:00:00:00:22",
		Hostname: "snmp-pve03",
		Metadata: map[string]string{"source": "snmp"},
	}
	job := &DiscoveryJob{
		ID: "job-deadline",
		Params: &DiscoveryParams{
			Options: map[string]string{proxmoxCandidateProbeOption: "true"},
		},
		Results: &DiscoveryResults{Devices: []*DiscoveredDevice{known}},
		deviceMap: map[string]*DeviceInterfaceMap{
			known.DeviceID: {
				DeviceID: known.DeviceID,
				IPs:      map[string]struct{}{known.IP: {}},
				MACs:     map[string]struct{}{known.MAC: {}},
			},
		},
	}
	engine := &DiscoveryEngine{
		config: &Config{Timeout: 2 * time.Second},
		logger: logger.NewTestLogger(),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	started := time.Now()
	engine.probeProxmoxCandidatesAfterIdentity(ctx, job, []string{"127.0.0.1"})
	elapsed := time.Since(started)

	hit, _ := hits.snapshot("127.0.0.2:8006", "")
	logDiscoveredDevices(t, job.Results.Devices)
	require.False(t, hit.IsZero(), "known device was not fingerprinted before the deadline")
	assert.Less(t, hit.Sub(started), 300*time.Millisecond, "fingerprint waited behind the silent seed")
	require.Len(t, job.Results.Devices, 1)
	assert.Equal(t, "mac-020000000022", job.Results.Devices[0].DeviceID)
	assert.Equal(t, "127.0.0.2", job.Results.Devices[0].IP)
	assert.Equal(t, "true", job.Results.Devices[0].Metadata["proxmox_candidate"])
	assert.Less(t, elapsed, 2*time.Second)
}

type discardPublisher struct{}

func (discardPublisher) PublishDevice(context.Context, *DiscoveredDevice) error { return nil }
func (discardPublisher) PublishInterface(context.Context, *DiscoveredInterface) error {
	return nil
}
func (discardPublisher) PublishTopologyLink(context.Context, *TopologyLink) error { return nil }

func newTestDiscoveryEngine(t *testing.T) *DiscoveryEngine {
	t.Helper()
	engine, err := NewDiscoveryEngine(&Config{
		Workers:       1,
		MaxActiveJobs: 4,
		Timeout:       2 * time.Second,
	}, discardPublisher{}, logger.NewTestLogger())
	require.NoError(t, err)
	return engine.(*DiscoveryEngine)
}

func waitForDiscoveryResults(t *testing.T, engine *DiscoveryEngine, discoveryID string) *DiscoveryResults {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		results, err := engine.GetDiscoveryResults(context.Background(), discoveryID, true)
		if err == nil {
			return results
		}
		lastErr = err
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatalf("discovery %s did not finish: %v", discoveryID, lastErr)
	return nil
}

func stageTimes(transitions []DiscoveryStageTransition) (time.Time, time.Time) {
	var identityDone, enrichDone time.Time
	for _, transition := range transitions {
		if transition.Stage == DiscoveryStageIdentity && transition.Status == DiscoveryStageStatusCompleted {
			identityDone = transition.Timestamp
		}
		if transition.Stage == DiscoveryStageEnrich && transition.Status == DiscoveryStageStatusCompleted {
			enrichDone = transition.Timestamp
		}
	}
	return identityDone, enrichDone
}

func deviceByIP(devices []*DiscoveredDevice, ip string) *DiscoveredDevice {
	for _, device := range devices {
		if device != nil && device.IP == ip {
			return device
		}
	}
	return nil
}

func logDiscoveredDevices(t *testing.T, devices []*DiscoveredDevice) {
	t.Helper()
	for _, device := range devices {
		if device == nil {
			continue
		}
		t.Logf("device id=%s ip=%s hostname=%s alt127.0.0.1=%q alt127.0.0.2=%q proxmox=%q source=%q",
			device.DeviceID, device.IP, device.Hostname,
			device.Metadata["alt_ip:127.0.0.1"], device.Metadata["alt_ip:127.0.0.2"],
			device.Metadata["proxmox_candidate"], device.Metadata["source"])
	}
}

func testPVECertificate(t *testing.T, ips ...net.IP) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	require.NoError(t, err)
	template := &x509.Certificate{
		SerialNumber: serial,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		IPAddresses:  ips,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	require.NoError(t, err)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func pvePage(node string) string {
	return "<html><head><title>" + node + " - Proxmox Virtual Environment</title></head></html>"
}

type pveHits struct {
	mu    sync.Mutex
	first map[string]time.Time
	count map[string]int
}

func newPVEHits() *pveHits {
	return &pveHits{
		first: map[string]time.Time{},
		count: map[string]int{},
	}
}

func (h *pveHits) record(addr string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.count[addr]++
	if _, ok := h.first[addr]; !ok {
		h.first[addr] = time.Now()
	}
}

func (h *pveHits) snapshot(firstAddr, countAddr string) (time.Time, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.first[firstAddr], h.count[countAddr]
}

func servePVE(t *testing.T, addr, body string, cert tls.Certificate, hits *pveHits) {
	t.Helper()
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", addr)
	require.NoError(t, err)
	tlsListener := tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{cert}})
	server := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hits.record(addr)
			_, _ = io.WriteString(w, body)
		}),
	}
	go func() {
		_ = server.Serve(tlsListener)
	}()
	t.Cleanup(func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	})
}

func serveSilentTCP(t *testing.T, addr string) {
	t.Helper()
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", addr)
	require.NoError(t, err)
	done := make(chan struct{})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				select {
				case <-done:
				case <-time.After(5 * time.Second):
				}
			}()
		}
	}()
	t.Cleanup(func() {
		close(done)
		_ = listener.Close()
	})
}
