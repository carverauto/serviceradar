package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

type fakeHTTPClient struct {
	requests []sdk.HTTPRequest
}

func (f *fakeHTTPClient) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)

	switch {
	case strings.HasSuffix(req.URL, "/api2/json/version"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"version":"8.2.4","release":"8.2","repoid":"test-repo"}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/cluster/status"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"id":"cluster/lab","name":"lab","type":"cluster","nodes":1,"quorate":1},{"id":"node/pve-a","name":"pve-a","type":"node","online":1,"ip":"10.10.0.11"}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"node":"pve-a","status":"online","cpu":0.25,"maxcpu":16,"mem":1024,"maxmem":4096,"uptime":3600}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/termproxy"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"port":5901,"ticket":"PVEVNC:ticket","user":"root@pam"}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/status"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"cpu":0.25,"wait":0.01,"memory":{"used":1024,"total":4096},"rootfs":{"used":2048,"total":8192}}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/storage"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"storage":"local-zfs","type":"zfspool","content":"images,rootdir","active":1,"enabled":1,"used":8192,"total":16384}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/network"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"iface":"vmbr0","type":"bridge","active":1,"exists":1,"method":"static","families":["inet"],"hwaddr":"00:aa:bb:cc:dd:ee","address":"10.10.0.11","cidr":"10.10.0.11/24","bridge-ports":"eno1"}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/disks/list"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"devpath":"/dev/sda","model":"Test SSD","type":"ssd","size":1024,"health":"PASSED"}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/ceph/status"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"health":{"status":"HEALTH_OK"},"fsid":"ceph-test"}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/ceph/osd"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"id":0,"name":"osd.0","up":1,"in":1}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/ceph/pool"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"pool_name":"rbd","size":3}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/ceph/fs"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"name":"cephfs"}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"id":"qemu/100","node":"pve-a","name":"vm-100","type":"qemu","status":"running","vmid":100,"cpu":0.1,"maxcpu":4,"mem":512,"maxmem":2048,"disk":1024,"maxdisk":4096}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/lxc"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/status/current"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"status":"running","cpu":0.1,"mem":512,"maxmem":2048}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/config"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"name":"vm-100","cores":4,"memory":2048,"agent":"1","api_token":"should-not-leak","net0":"virtio=00:11:22:33:44:55,bridge=vmbr0"}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/agent/network-get-interfaces"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"result":[{"name":"eth0","hardware-address":"00:11:22:33:44:55","ip-addresses":[{"ip-address":"192.168.2.50","ip-address-type":"ipv4","prefix":24},{"ip-address":"fe80::1","ip-address-type":"ipv6","prefix":64}]}]}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/agent/get-fsinfo"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"result":[{"name":"sda1","mountpoint":"/","type":"ext4","total-bytes":8192,"used-bytes":6144},{"name":"tmpfs","mountpoint":"/run","type":"tmpfs","total-bytes":2048,"used-bytes":128}]}}`),
		}, nil
	default:
		return &sdk.HTTPResponse{Status: http.StatusNotFound, Body: []byte(`{}`)}, nil
	}
}

type staticHTTPClient struct {
	response *sdk.HTTPResponse
}

func (s staticHTTPClient) Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	return s.response, nil
}

func TestRunProxmoxCheckBuildsInventory(t *testing.T) {
	client := &fakeHTTPClient{}
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = client
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	// The plugin streams one result per node instead of a single aggregate, so
	// capture every submitted batch rather than reading the (summary-only)
	// return value.
	var batches []*pluginResult
	oldSubmit := submitResult
	submitResult = func(r *pluginResult) error {
		batches = append(batches, r)
		return nil
	}
	t.Cleanup(func() { submitResult = oldSubmit })

	result, err := runProxmoxCheck(Config{
		BaseURL:       "https://pve-a.example:8006/",
		APIToken:      "PVEAPIToken=root@pam!sr=test-token",
		IncludeGuests: boolPtr(true),
	})
	if err != nil {
		t.Fatalf("runProxmoxCheck() error = %v", err)
	}

	if result.Status != sdk.StatusOK {
		t.Fatalf("unexpected status: %s summary=%s", result.Status, result.Summary)
	}
	if !strings.Contains(result.Summary, "1 node(s), 1 guest(s)") {
		t.Fatalf("expected aggregate counts in summary, got %q", result.Summary)
	}
	if len(client.requests) != 13 {
		t.Fatalf("expected thirteen Proxmox API requests, got %d", len(client.requests))
	}
	for _, req := range client.requests {
		if strings.Contains(req.URL, "/api2/json/cluster/resources") {
			t.Fatalf("guest inventory must not use the cluster-wide resources endpoint, got %s", req.URL)
		}
	}
	if client.requests[0].Headers["Authorization"] != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("authorization header was not set")
	}
	if len(batches) < 2 {
		t.Fatalf("expected streamed node + guest batches, got %d", len(batches))
	}

	// Locate the node-bearing and guest-bearing batches, and the streamed guest
	// device discovery.
	var nodeDetails, guestDetails *proxmoxTarget
	guestDiscoveryIP := ""
	for _, b := range batches {
		var d proxmoxDetails
		if err := json.Unmarshal([]byte(b.Details), &d); err != nil {
			t.Fatalf("decode batch details: %v", err)
		}
		if len(d.Targets) == 0 {
			continue
		}
		tgt := d.Targets[0]
		switch {
		case len(tgt.Guests) > 0:
			g := tgt
			guestDetails = &g
			// Guest batches carry only guest devices in their discovery.
			for _, disc := range b.DeviceDiscovery {
				for _, dev := range disc.Devices {
					if dev.IP != "" {
						guestDiscoveryIP = dev.IP
					}
				}
			}
		case len(tgt.Nodes) > 0 && nodeDetails == nil:
			n := tgt
			nodeDetails = &n
		}
	}
	if nodeDetails == nil || guestDetails == nil {
		t.Fatalf("expected both a node and a guest batch (node=%v guest=%v)", nodeDetails, guestDetails)
	}

	// Version + cluster identity must travel with every batch so per-node guest
	// batches can still mint the v2 identity.
	if guestDetails.Version == nil || guestDetails.Version.Version != "8.2.4" {
		t.Fatalf("expected version on guest batch, got %#v", guestDetails.Version)
	}
	if len(guestDetails.Cluster) != 2 {
		t.Fatalf("expected cluster status on guest batch, got %#v", guestDetails.Cluster)
	}

	node := nodeDetails.Nodes[0]
	if node.IP != "10.10.0.11" {
		t.Fatalf("expected node IP from cluster status, got %#v", node)
	}
	if floatValue(node.RuntimeState, "wait") != 0.01 {
		t.Fatalf("expected node runtime status, got %#v", node.RuntimeState)
	}
	if len(node.Storage) != 1 || node.Storage[0].Storage != "local-zfs" {
		t.Fatalf("expected node storage details, got %#v", node.Storage)
	}
	if len(node.Network) != 1 || node.Network[0].Iface != "vmbr0" || node.Network[0].MACAddress != "00:aa:bb:cc:dd:ee" {
		t.Fatalf("expected node network details, got %#v", node.Network)
	}
	if len(node.Disks) != 1 || node.Disks[0].DevPath != "/dev/sda" {
		t.Fatalf("expected node disk details, got %#v", node.Disks)
	}

	guest := guestDetails.Guests[0]
	if len(guest.Interfaces) != 1 {
		t.Fatalf("expected guest interface details, got %#v", guest.Interfaces)
	}
	if got := guest.Interfaces[0].IPAddresses; len(got) != 1 || got[0] != "192.168.2.50/24" {
		t.Fatalf("expected guest agent IP address, got %#v", got)
	}
	if guest.Disk != 6144 || guest.MaxDisk != 8192 {
		t.Fatalf("expected guest agent filesystem usage, got disk=%v maxdisk=%v", guest.Disk, guest.MaxDisk)
	}
	if guestDiscoveryIP != "192.168.2.50" {
		t.Fatalf("expected guest discovery IP from guest agent, got %q", guestDiscoveryIP)
	}
}

func TestFetchGuestsUsesNodeScopedEndpointsAndLXCConfigIPs(t *testing.T) {
	client := &nodeScopedGuestHTTPClient{}
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = client
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	cfg := Config{BaseURL: "https://pve-a.example:8006", APIToken: "PVEAPIToken=root@pam!sr=test-token"}
	cfg.applyDefaults()

	warnings := map[string]string{}
	guestResources := fetchGuests(
		cfg,
		Target{BaseURL: cfg.BaseURL},
		cfg.APIToken,
		[]proxmoxNode{{Node: "pve-a", Status: "online"}},
		warnings,
	)
	guests := enrichGuests(cfg, Target{BaseURL: cfg.BaseURL}, cfg.APIToken, guestResources, warnings)

	if len(guests) != 2 {
		t.Fatalf("expected qemu and lxc guests, got %#v warnings=%#v", guests, warnings)
	}
	if len(warnings) != 0 {
		t.Fatalf("expected no guest warnings, got %#v", warnings)
	}
	for _, url := range client.urls {
		if strings.Contains(url, "/api2/json/cluster/resources") {
			t.Fatalf("guest inventory must not use the cluster-wide resources endpoint, got %s", url)
		}
	}

	var lxc proxmoxGuest
	for _, guest := range guests {
		if guestEndpointKind(guest.Type) == "lxc" {
			lxc = guest
			break
		}
	}
	if lxc.VMID != 200 {
		t.Fatalf("expected LXC vmid 200, got %#v", lxc.proxmoxResource)
	}
	if got := primaryIP(lxc.Interfaces); got != "192.168.2.73" {
		t.Fatalf("expected LXC primary IP from config, got %q interfaces=%#v", got, lxc.Interfaces)
	}
	if got := primaryMAC(lxc.Interfaces); got != "BC:24:11:53:84:67" {
		t.Fatalf("expected LXC MAC from config, got %q interfaces=%#v", got, lxc.Interfaces)
	}
}

type nodeScopedGuestHTTPClient struct {
	urls []string
}

func (c *nodeScopedGuestHTTPClient) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	c.urls = append(c.urls, req.URL)

	switch {
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"vmid":100,"name":"vm-100","status":"stopped","maxcpu":4,"maxmem":2048,"maxdisk":4096}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/lxc"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"vmid":200,"name":"ct-200","status":"stopped","maxcpu":2,"maxmem":1024,"maxdisk":2048}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/config"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"name":"vm-100","net0":"virtio=00:11:22:33:44:55,bridge=vmbr0,ip=192.168.2.50/24"}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/lxc/200/config"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"hostname":"ct-200","net0":"name=eth0,bridge=vmbr0,hwaddr=bc:24:11:53:84:67,ip=192.168.2.73/24,type=veth"}}`),
		}, nil
	default:
		return &sdk.HTTPResponse{Status: http.StatusNotFound, Body: []byte(`{"message":"not found"}`)}, nil
	}
}

func TestEmitResourceEventsAddsOCSFEvents(t *testing.T) {
	result := newPluginResult(sdk.StatusWarning, "resource pressure")
	emitResourceEvents(result, proxmoxDetails{Targets: []proxmoxTarget{
		{
			BaseURL: "https://pve-a.example:8006",
			Nodes: []proxmoxNode{
				{
					Node:         "pve-a",
					CPU:          0.91,
					Mem:          950,
					MaxMem:       1000,
					RuntimeState: proxmoxNodeStatus{Wait: 0.41},
				},
			},
			Guests: []proxmoxGuest{
				{proxmoxResource: proxmoxResource{Type: "qemu", VMID: 100, CPU: 0.85, Mem: 900, MaxMem: 1000}},
			},
		},
	}})

	if len(result.TelemetryEvents) < 5 {
		t.Fatalf("expected resource telemetry events, got %#v", result.TelemetryEvents)
	}

	var payload map[string]any
	if err := json.Unmarshal(result.JSON(), &payload); err != nil {
		t.Fatalf("result JSON should be valid: %v", err)
	}
	if _, ok := payload["events"]; ok {
		t.Fatalf("expected result payload to omit first-class telemetry events, got %#v", payload["events"])
	}

	record := sdk.NewOCSFTelemetryRecord(result.TelemetryEvents[0]).WithSignalSchemaRef(proxmoxSignalSchemaRef())
	if record.Metadata["serviceradar.signal_schema."+sdk.SignalSchemaMetadataSchemaID] != proxmoxSignalSchemaID {
		t.Fatalf("schema id = %#v, want %q", record.Metadata, proxmoxSignalSchemaID)
	}
	if record.Metadata["serviceradar.signal_schema."+sdk.SignalSchemaMetadataDisplayContract] != proxmoxSignalSchemaDisplayContractPath {
		t.Fatalf(
			"display contract metadata = %#v, want %q",
			record.Metadata,
			proxmoxSignalSchemaDisplayContractPath,
		)
	}
}

func TestInterfacesFromLXCInterfacesIncludesRuntimeDHCPAddress(t *testing.T) {
	interfaces := interfacesFromLXCInterfaces([]proxmoxLXCInterface{
		{Name: "lo", Inet: "127.0.0.1/8"},
		{Name: "eth0", MACAddress: "bc:24:11:53:84:67", Inet: "192.168.2.73/24", Inet6: "fe80::1/64"},
	})

	if len(interfaces) != 1 {
		t.Fatalf("expected only the routable eth0 interface record, got %#v", interfaces)
	}
	got := interfaces[0]
	if got.MACAddress != "BC:24:11:53:84:67" || got.Source != "lxc_interfaces" {
		t.Fatalf("expected normalized LXC interface identity, got %#v", got)
	}
	if len(got.IPAddresses) != 1 || got.IPAddresses[0] != "192.168.2.73/24" {
		t.Fatalf("expected non-link-local LXC address, got %#v", got.IPAddresses)
	}
}

func TestGetJSONIncludesSanitizedHTTPErrorBody(t *testing.T) {
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = staticHTTPClient{response: &sdk.HTTPResponse{
		Status: http.StatusInternalServerError,
		Body:   []byte(`{"data":"QEMU guest agent is not running","token":"PVEAPIToken=root@pam!sr=super-secret"}`),
	}}
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	var out map[string]any
	err := getJSON(Config{TimeoutMS: defaultTimeoutMS}, Target{BaseURL: "https://pve.example:8006"}, "PVEAPIToken=root@pam!sr=test", "/api2/json/test", &out)
	if err == nil {
		t.Fatal("expected HTTP error")
	}

	got := err.Error()
	if !strings.Contains(got, "HTTP 500") || !strings.Contains(got, "QEMU guest agent is not running") {
		t.Fatalf("expected status and response body in error, got %q", got)
	}
	if strings.Contains(got, "super-secret") {
		t.Fatalf("expected PVE token to be redacted, got %q", got)
	}
}

func TestRunProxmoxCheckAcceptsBareAPITokenMaterial(t *testing.T) {
	client := &fakeHTTPClient{}
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = client
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	includeGuests := false
	result, err := runProxmoxCheck(Config{
		BaseURL:       "https://pve-a.example:8006/",
		APIToken:      "root@pam!sr=test-token",
		IncludeGuests: &includeGuests,
	})
	if err != nil {
		t.Fatalf("runProxmoxCheck() error = %v", err)
	}
	if result.Status != sdk.StatusOK {
		t.Fatalf("unexpected status: %s", result.Status)
	}
	if got := client.requests[0].Headers["Authorization"]; got != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("expected normalized Proxmox API token header, got %q", got)
	}
}

func boolPtr(value bool) *bool {
	return &value
}

func TestConfigFromMapBuildsTargetsFromPluginInputs(t *testing.T) {
	cfg, err := configFromMap(map[string]any{
		"schema":         sdk.PluginInputsSchemaV1,
		"policy_id":      "policy-1",
		"policy_version": 1,
		"agent_id":       "agent-1",
		"generated_at":   "2026-05-06T19:00:00Z",
		"template": map[string]any{
			"credential_broker": map[string]any{
				"schema":                "serviceradar.edge_credential_broker_grant.v1",
				"credential_secret_ref": "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
			},
			"include_guests": false,
			"timeout_ms":     45000,
		},
		"inputs": []any{
			map[string]any{
				"name":        "targets",
				"entity":      "devices",
				"query":       "in:devices tags.provider:proxmox",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash":  strings.Repeat("a", 64),
				"items": []any{
					map[string]any{
						"uid":       "sr:device:1",
						"ip":        "10.10.0.11",
						"hostname":  "pve-a",
						"partition": "dc-a",
					},
					map[string]any{
						"uid":              "sr:device:2",
						"proxmox_base_url": "https://pve-b.example:8006/",
						"hostname":         "pve-b",
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("configFromMap() error = %v", err)
	}

	if cfg.TimeoutMS != 45000 {
		t.Fatalf("unexpected timeout: %d", cfg.TimeoutMS)
	}
	if cfg.includeGuests() {
		t.Fatalf("expected include_guests=false from template")
	}
	if got := len(cfg.Targets); got != 2 {
		t.Fatalf("expected two generated targets, got %d", got)
	}
	if cfg.Targets[0].BaseURL != "https://10.10.0.11:8006" {
		t.Fatalf("unexpected first target URL: %s", cfg.Targets[0].BaseURL)
	}
	if cfg.Targets[0].APIToken != "" {
		t.Fatalf("plugin input targets must not inherit raw API tokens")
	}
	if cfg.CredentialBroker["schema"] != "serviceradar.edge_credential_broker_grant.v1" {
		t.Fatalf("expected broker grant to stay in the template")
	}
	if cfg.Targets[0].DeviceID != "sr:device:1" || cfg.Targets[0].Partition != "dc-a" {
		t.Fatalf("unexpected first target metadata: %#v", cfg.Targets[0])
	}
	if cfg.Targets[1].BaseURL != "https://pve-b.example:8006" {
		t.Fatalf("unexpected second target URL: %s", cfg.Targets[1].BaseURL)
	}
}

func TestConfigFromJSONBuildsTargetsFromPluginInputs(t *testing.T) {
	cfg, err := configFromJSON(json.RawMessage(`{
		"schema": "serviceradar.plugin_inputs.v1",
		"policy_id": "policy-1",
		"policy_version": 1,
		"agent_id": "agent-1",
		"generated_at": "2026-05-06T19:00:00Z",
		"template": {
			"api_token_secret_ref": "credentialref:network-credential-secret:test-secret",
			"api_token": "PVEAPIToken=root@pam!sr=test-token",
			"include_guests": true,
			"timeout_ms": 45000,
			"credential_broker": {
				"schema": "serviceradar.edge_credential_broker_grant.v1",
				"allow": {"methods": ["GET"], "paths": ["/api2/json/version"]}
			}
		},
		"inputs": [{
			"name": "targets",
			"entity": "devices",
			"query": "in:devices metadata.proxmox_candidate:true",
			"chunk_index": 0,
			"chunk_total": 1,
			"chunk_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			"items": [
				{"uid": "sr:device:1", "ip": "10.10.0.11", "hostname": "pve-a", "partition": "dc-a"},
				{"uid": "sr:device:2", "proxmox_base_url": "https://pve-b.example:8006/", "hostname": "pve-b"}
			]
		}]
	}`))
	if err != nil {
		t.Fatalf("configFromJSON() error = %v", err)
	}

	if cfg.TimeoutMS != 45000 {
		t.Fatalf("unexpected timeout: %d", cfg.TimeoutMS)
	}
	if !cfg.includeGuests() {
		t.Fatalf("expected include_guests=true from template")
	}
	if cfg.APIToken != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("expected template API token, got %q", cfg.APIToken)
	}
	if got := len(cfg.Targets); got != 2 {
		t.Fatalf("expected two generated targets, got %d", got)
	}
	if cfg.Targets[0].BaseURL != "https://10.10.0.11:8006" {
		t.Fatalf("unexpected first target URL: %s", cfg.Targets[0].BaseURL)
	}
	if cfg.Targets[0].DeviceID != "sr:device:1" || cfg.Targets[0].Partition != "dc-a" {
		t.Fatalf("unexpected first target metadata: %#v", cfg.Targets[0])
	}
	if cfg.Targets[1].BaseURL != "https://pve-b.example:8006" {
		t.Fatalf("unexpected second target URL: %s", cfg.Targets[1].BaseURL)
	}
}

func TestConfigFromMapAppliesRuntimeResolvedAPITokenToPluginInputTargets(t *testing.T) {
	cfg, err := configFromMap(map[string]any{
		"schema":         sdk.PluginInputsSchemaV1,
		"policy_id":      "policy-1",
		"policy_version": 1,
		"agent_id":       "agent-1",
		"generated_at":   "2026-05-06T19:00:00Z",
		"template": map[string]any{
			"api_token_secret_ref": "credentialref:network-credential-secret:test-secret",
			"api_token":            "PVEAPIToken=root@pam!sr=test-token",
		},
		"inputs": []any{
			map[string]any{
				"name":        "targets",
				"entity":      "devices",
				"query":       "in:devices metadata.proxmox_candidate:true",
				"chunk_index": 0,
				"chunk_total": 1,
				"chunk_hash":  strings.Repeat("a", 64),
				"items": []any{
					map[string]any{"uid": "sr:device:1", "ip": "10.10.0.11", "hostname": "pve-a"},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("configFromMap() error = %v", err)
	}

	if cfg.APIToken != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("expected runtime api token to be applied")
	}
	if len(cfg.Targets) != 1 {
		t.Fatalf("expected one target, got %d", len(cfg.Targets))
	}
	if cfg.Targets[0].APIToken != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("expected runtime api token to be inherited by generated target")
	}
}

func TestAddNodeDiscoveriesOnlyUsesTargetDeviceIDForMatchingNode(t *testing.T) {
	discovery := sdk.NewDeviceDiscovery(discoverySource)

	addNodeDiscoveries(discovery, Target{
		BaseURL:  "https://pve-a.example:8006",
		DeviceID: "sr:device:pve-a",
		Hostname: "pve-a.example",
	}, []proxmoxNode{
		{Node: "pve-a", Status: "online", IP: "192.0.2.10/24"},
		{Node: "pve-b", Status: "online", IP: "192.0.2.11/24"},
	})

	if got := discovery.Devices[0].DeviceID; got != "sr:device:pve-a" {
		t.Fatalf("expected matching node to keep target device ID, got %s", got)
	}
	if got := discovery.Devices[1].DeviceID; got != "proxmox:pve:pve-b" {
		t.Fatalf("expected non-target cluster node to get stable Proxmox ID, got %s", got)
	}
	if got := discovery.Devices[1].IP; got != "192.0.2.11" {
		t.Fatalf("expected non-target cluster node discovery IP, got %s", got)
	}
}

func TestAnnotateNodesWithClusterStatusCopiesNodeIPs(t *testing.T) {
	nodes := annotateNodesWithClusterStatus(
		[]proxmoxNode{
			{Node: "pve-a", Status: "online"},
			{Node: "pve-b", Status: "online", IP: "192.0.2.20"},
			{Node: "pve-c", Status: "online", Network: []proxmoxNetworkInterface{{Iface: "vmbr0", Address: "192.0.2.30/24"}}},
		},
		[]proxmoxClusterNode{
			{ID: "cluster/lab", Name: "lab", Type: "cluster"},
			{ID: "node/pve-a", Type: "node", IP: "192.0.2.10"},
			{Name: "pve-b", Type: "node", IP: "192.0.2.21"},
			{Name: "pve-c", Type: "node"},
		},
	)

	if nodes[0].IP != "192.0.2.10" {
		t.Fatalf("expected pve-a IP from cluster status, got %#v", nodes[0])
	}
	if nodes[1].IP != "192.0.2.20" {
		t.Fatalf("expected existing pve-b IP to be preserved, got %#v", nodes[1])
	}
	if nodes[2].IP != "192.0.2.30" {
		t.Fatalf("expected pve-c IP from node network config, got %#v", nodes[2])
	}
}

func TestInterfacesFromGuestConfigParsesLXCAndQEMU(t *testing.T) {
	interfaces := interfacesFromGuestConfig(map[string]string{
		"net0": "name=eth0,bridge=vmbr0,gw=192.168.2.1,hwaddr=bc:24:11:76:df:7e,ip=192.168.2.15/24,type=veth",
		"net1": "virtio=00-11-22-33-44-55,bridge=vmbr1,tag=20",
	})

	if len(interfaces) != 2 {
		t.Fatalf("expected two interfaces, got %#v", interfaces)
	}
	if interfaces[0].MACAddress != "BC:24:11:76:DF:7E" || interfaces[0].IPAddresses[0] != "192.168.2.15/24" {
		t.Fatalf("unexpected LXC interface: %#v", interfaces[0])
	}
	if interfaces[1].MACAddress != "00:11:22:33:44:55" || interfaces[1].Model != "virtio" || interfaces[1].VLANID != 20 {
		t.Fatalf("unexpected QEMU interface: %#v", interfaces[1])
	}
}

func TestRunProxmoxCheckRequiresTargetAndToken(t *testing.T) {
	if _, err := runProxmoxCheck(Config{APIToken: "token"}); err != errMissingTarget {
		t.Fatalf("expected missing target, got %v", err)
	}

	if _, err := runProxmoxCheck(Config{BaseURL: "https://pve.example:8006"}); err == nil || !strings.Contains(err.Error(), errMissingToken.Error()) {
		t.Fatalf("expected missing token, got %v", err)
	}
}

func TestConfigSchemaOnlyExposesInternalAPITokenSecretRef(t *testing.T) {
	raw, err := os.ReadFile("config.schema.json")
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}

	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("decode schema: %v", err)
	}

	properties := schema["properties"].(map[string]any)
	if _, ok := properties["api_token"]; ok {
		t.Fatal("published schema must not expose raw api_token")
	}
	apiTokenRef, ok := properties["api_token_secret_ref"].(map[string]any)
	if !ok {
		t.Fatal("published schema must include internal api_token_secret_ref for runtime resolution")
	}
	if apiTokenRef["secretRef"] != true {
		t.Fatal("api_token_secret_ref must be a secretRef field")
	}
	if apiTokenRef["x-serviceradar-ui-hidden"] != true || apiTokenRef["x-serviceradar-internal"] != true {
		t.Fatal("api_token_secret_ref must stay hidden/internal")
	}
	if properties["base_url"].(map[string]any)["x-serviceradar-ui-hidden"] != true {
		t.Fatal("base_url must stay hidden from central assignment UI")
	}

	targets := properties["targets"].(map[string]any)
	if targets["x-serviceradar-ui-hidden"] != true {
		t.Fatal("targets must stay hidden from central assignment UI")
	}
	items := targets["items"].(map[string]any)
	targetProperties := items["properties"].(map[string]any)
	if _, ok := targetProperties["api_token"]; ok {
		t.Fatal("published target schema must not expose raw api_token")
	}
}

func TestValidateConsoleConfigRequiresScopedBroker(t *testing.T) {
	cfg := consoleConfig{
		CredentialRuleID: "rule-1",
		CredentialBroker: map[string]any{"schema": "serviceradar.edge_credential_broker_grant.v1"},
		Console:          consoleContext{SessionID: "session-1"},
		Target:           consoleTarget{Hostname: "pve.example"},
		TimeoutMS:        defaultTimeoutMS,
	}

	if err := validateConsoleConfig(cfg); err != nil {
		t.Fatalf("validateConsoleConfig returned error: %v", err)
	}

	cfg.CredentialBroker = nil
	if err := validateConsoleConfig(cfg); err == nil || !strings.Contains(err.Error(), "credential_broker") {
		t.Fatalf("expected credential_broker validation error, got %v", err)
	}
}

func TestConsoleConfigSchemaHidesAgentLocalSecrets(t *testing.T) {
	raw, err := os.ReadFile("config.console.schema.json")
	if err != nil {
		t.Fatalf("read console schema: %v", err)
	}

	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("decode console schema: %v", err)
	}

	properties := schema["properties"].(map[string]any)
	for _, key := range []string{"target", "ssh"} {
		if properties[key].(map[string]any)["x-serviceradar-ui-hidden"] != true {
			t.Fatalf("%s must stay hidden from central assignment UI", key)
		}
	}
	sshProperties := properties["ssh"].(map[string]any)["properties"].(map[string]any)
	for _, key := range []string{"password", "private_key", "passphrase"} {
		if sshProperties[key].(map[string]any)["x-serviceradar-sensitive"] != true {
			t.Fatalf("ssh.%s must be marked sensitive", key)
		}
	}
}

func TestConsoleConfigFromPluginInputsSelectsScopedTarget(t *testing.T) {
	cfg, err := consoleConfigFromMap(map[string]any{
		"schema":         sdk.PluginInputsSchemaV1,
		"policy_id":      "policy-1",
		"policy_version": float64(1),
		"agent_id":       "agent-1",
		"generated_at":   "2026-05-07T00:00:00Z",
		"template": map[string]any{
			"credential_broker":  map[string]any{"schema": "serviceradar.edge_credential_broker_grant.v1"},
			"credential_rule_id": "rule-1",
		},
		"console": map[string]any{
			"session_id":         "session-1",
			"device_uid":         "device-b",
			"credential_rule_id": "rule-1",
			"console_mode":       "ssh",
		},
		"inputs": []any{
			map[string]any{
				"name":        "targets",
				"entity":      "devices",
				"query":       "in:devices tag:proxmox",
				"chunk_index": float64(0),
				"chunk_total": float64(1),
				"chunk_hash":  strings.Repeat("a", 64),
				"items": []any{
					map[string]any{"uid": "device-a", "hostname": "pve-a.example", "ip": "192.0.2.10"},
					map[string]any{"uid": "device-b", "hostname": "pve-b.example", "ip": "192.0.2.11", "ssh_port": float64(2222)},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("consoleConfigFromMap returned error: %v", err)
	}

	if cfg.Console.SessionID != "session-1" {
		t.Fatalf("expected console context to be applied, got %#v", cfg.Console)
	}
	if cfg.Target.DeviceUID != "device-b" || cfg.Target.Hostname != "pve-b.example" || cfg.Target.IP != "192.0.2.11" {
		t.Fatalf("expected selected device-b target, got %#v", cfg.Target)
	}
	if cfg.Target.SSHPort != 2222 {
		t.Fatalf("expected ssh_port 2222, got %d", cfg.Target.SSHPort)
	}
}

func TestRunConsoleWithDepsStreamsSSHSession(t *testing.T) {
	bridge := newFakeConsoleBridge(
		consoleInputFrame{FrameType: "data", Data: []byte("uptime\n")},
		consoleInputFrame{FrameType: "resize", Cols: 100, Rows: 30},
		consoleInputFrame{FrameType: "close"},
	)
	session := &fakeSSHSession{
		waitCh: make(chan struct{}),
		stdout: strings.NewReader("login banner\r\n"),
		stderr: strings.NewReader(""),
	}
	cfg := consoleConfig{
		CredentialRuleID: "rule-1",
		CredentialBroker: map[string]any{"schema": "serviceradar.edge_credential_broker_grant.v1"},
		Console:          consoleContext{SessionID: "session-1", ConsoleMode: "ssh", Cols: 80, Rows: 24},
		Target:           consoleTarget{Hostname: "pve.example"},
		TimeoutMS:        defaultTimeoutMS,
	}

	err := runConsoleWithDeps(cfg, consoleDeps{
		openBridge: func(req consoleOpenRequest) (proxmoxConsoleBridge, error) {
			if req.TerminalType != "xterm-256color" {
				t.Fatalf("unexpected terminal type %q", req.TerminalType)
			}
			return bridge, nil
		},
		dialSSH: func(got consoleConfig) (sshConsoleSession, error) {
			if got.Target.Hostname != "pve.example" {
				t.Fatalf("unexpected SSH target %#v", got.Target)
			}
			return session, nil
		},
	})
	if err != nil {
		t.Fatalf("runConsoleWithDeps returned error: %v", err)
	}

	if !session.shellStarted || !session.closed {
		t.Fatalf("expected shell to start and close, got shell=%t closed=%t", session.shellStarted, session.closed)
	}
	if session.ptyRows != 24 || session.ptyCols != 80 {
		t.Fatalf("expected initial PTY 24x80, got %dx%d", session.ptyRows, session.ptyCols)
	}
	if got := session.stdin.String(); got != "uptime\n" {
		t.Fatalf("expected stdin data, got %q", got)
	}
	if len(session.windowChanges) != 1 || session.windowChanges[0] != [2]int{30, 100} {
		t.Fatalf("expected resize to 30x100, got %#v", session.windowChanges)
	}
	select {
	case <-bridge.writeCh:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for SSH stdout to be written to bridge")
	}
	if !strings.Contains(bridge.Output(), "login banner") {
		t.Fatalf("expected bridge output to contain SSH stdout, got %q", bridge.Output())
	}
}

func TestRunConsoleWithDepsStreamsNativeProxmoxConsole(t *testing.T) {
	client := &fakeHTTPClient{}
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = client
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	bridge := newFakeConsoleBridge(consoleInputFrame{FrameType: "close"})
	ws := &fakeWebSocketConn{}
	cfg := consoleConfig{
		CredentialRuleID:   "rule-1",
		CredentialBroker:   map[string]any{"schema": "serviceradar.edge_credential_broker_grant.v1"},
		APIToken:           "root@pam!sr=test-token",
		Console:            consoleContext{SessionID: "session-1", ConsoleMode: "proxmox_termproxy", TargetKind: "pve_host"},
		Target:             consoleTarget{BaseURL: "https://pve.example:8006", ProviderRef: "proxmox:node:pve-a"},
		TimeoutMS:          defaultTimeoutMS,
		InsecureSkipVerify: true,
	}

	err := runConsoleWithDeps(cfg, consoleDeps{
		openBridge: func(req consoleOpenRequest) (proxmoxConsoleBridge, error) {
			if req.TerminalType != "xterm-256color" {
				t.Fatalf("unexpected terminal type %q", req.TerminalType)
			}
			return bridge, nil
		},
		dialWS: func(_ context.Context, req sdk.WebSocketDialRequest, _ time.Duration) (websocketConsoleConn, error) {
			ws.url = req.URL
			ws.headers = req.Headers
			ws.insecureSkipVerify = req.InsecureSkipVerify
			return ws, nil
		},
	})
	if err != nil {
		t.Fatalf("runConsoleWithDeps returned error: %v", err)
	}
	if len(client.requests) != 1 {
		t.Fatalf("expected one Proxmox proxy request, got %d", len(client.requests))
	}
	if client.requests[0].Method != http.MethodPost {
		t.Fatalf("expected POST proxy request, got %s", client.requests[0].Method)
	}
	if got := client.requests[0].Headers["Authorization"]; got != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("unexpected Authorization header %q", got)
	}
	if !strings.HasPrefix(ws.url, "wss://pve.example:8006/api2/json/nodes/pve-a/vncwebsocket?") {
		t.Fatalf("unexpected websocket URL %q", ws.url)
	}
	if ws.headers["Authorization"] != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("unexpected websocket Authorization header %q", ws.headers["Authorization"])
	}
	if !ws.insecureSkipVerify {
		t.Fatal("expected websocket to inherit insecure_skip_verify")
	}
	if !ws.closed {
		t.Fatal("expected websocket to close")
	}
}

type fakeConsoleBridge struct {
	mu          sync.Mutex
	writes      bytes.Buffer
	readFrames  [][]byte
	closeReason string
	writeCh     chan struct{}
}

func newFakeConsoleBridge(frames ...consoleInputFrame) *fakeConsoleBridge {
	bridge := &fakeConsoleBridge{writeCh: make(chan struct{}, 8)}
	for _, frame := range frames {
		encoded, _ := json.Marshal(frame)
		bridge.readFrames = append(bridge.readFrames, encoded)
	}
	return bridge
}

func (f *fakeConsoleBridge) Write(payload []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	_, err := f.writes.Write(payload)
	select {
	case f.writeCh <- struct{}{}:
	default:
	}
	return err
}

func (f *fakeConsoleBridge) Read(buf []byte, _ time.Duration) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.readFrames) == 0 {
		return 0, nil
	}
	frame := f.readFrames[0]
	f.readFrames = f.readFrames[1:]
	return copy(buf, frame), nil
}

func (f *fakeConsoleBridge) Close(reason string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closeReason = reason
	return nil
}

func (f *fakeConsoleBridge) Output() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.writes.String()
}

type fakeSSHSession struct {
	stdin         bytes.Buffer
	stdout        io.Reader
	stderr        io.Reader
	ptyRows       int
	ptyCols       int
	windowChanges [][2]int
	shellStarted  bool
	closed        bool
	waitCh        chan struct{}
	waitOnce      sync.Once
}

type fakeWebSocketConn struct {
	url                string
	headers            map[string]string
	insecureSkipVerify bool
	closed             bool
}

func (f *fakeWebSocketConn) SendContext(_ context.Context, _ []byte, _ time.Duration) error {
	return nil
}

func (f *fakeWebSocketConn) RecvContext(_ context.Context, _ []byte, _ time.Duration) (int, error) {
	return 0, sdk.HostError{Code: -6, Op: "websocket_recv"}
}

func (f *fakeWebSocketConn) Close() error {
	f.closed = true
	return nil
}

func (f *fakeSSHSession) StdinPipe() (io.WriteCloser, error) {
	return nopWriteCloser{Writer: &f.stdin}, nil
}

func (f *fakeSSHSession) StdoutPipe() (io.Reader, error) { return f.stdout, nil }
func (f *fakeSSHSession) StderrPipe() (io.Reader, error) { return f.stderr, nil }

func (f *fakeSSHSession) RequestPty(_ string, h, w int) error {
	f.ptyRows = h
	f.ptyCols = w
	return nil
}

func (f *fakeSSHSession) WindowChange(h, w int) error {
	f.windowChanges = append(f.windowChanges, [2]int{h, w})
	return nil
}

func (f *fakeSSHSession) Shell() error {
	f.shellStarted = true
	return nil
}

func (f *fakeSSHSession) Wait() error {
	if f.waitCh == nil {
		f.waitCh = make(chan struct{})
	}
	<-f.waitCh
	return nil
}

func (f *fakeSSHSession) Close() error {
	f.closed = true
	if f.waitCh != nil {
		f.waitOnce.Do(func() { close(f.waitCh) })
	}
	return nil
}

type nopWriteCloser struct {
	io.Writer
}

func (n nopWriteCloser) Close() error { return nil }

func TestInterfacesFromGuestConfigMergesIPConfig(t *testing.T) {
	// Cloud-init QEMU: netN has the MAC, ipconfigN has the address.
	config := map[string]string{
		"net0":      "virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0",
		"ipconfig0": "ip=10.0.0.5/24,gw=10.0.0.1",
	}
	ifaces := interfacesFromGuestConfig(config)
	if len(ifaces) != 1 {
		t.Fatalf("expected 1 interface, got %d: %+v", len(ifaces), ifaces)
	}
	if ifaces[0].MACAddress == "" {
		t.Fatalf("expected MAC from net0, got none")
	}
	// primaryIP strips the CIDR prefix — the device IP is the bare address.
	if ip := primaryIP(ifaces); ip != "10.0.0.5" {
		t.Fatalf("expected ipconfig0 address 10.0.0.5 merged onto net0, got primaryIP=%q ips=%+v", ip, ifaces[0].IPAddresses)
	}
}

func TestGuestAgentEnabled(t *testing.T) {
	cases := map[string]bool{
		"1":                          true,
		"1,fstrim_cloned_disks=1":    true,
		"enabled=1,type=virtio":      true,
		"0":                          false,
		"":                           false,
		"enabled=0":                  false,
	}
	for raw, want := range cases {
		if got := guestAgentEnabled(map[string]string{"agent": raw}); got != want {
			t.Fatalf("guestAgentEnabled(%q) = %v, want %v", raw, got, want)
		}
	}
}
