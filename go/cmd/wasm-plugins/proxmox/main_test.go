package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

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
			Body:   []byte(`{"data":[{"id":"cluster/lab","name":"lab","type":"cluster","nodes":1,"quorate":1},{"id":"node/pve-a","name":"pve-a","type":"node","online":1}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"node":"pve-a","status":"online","cpu":0.25,"maxcpu":16,"mem":1024,"maxmem":4096,"uptime":3600}]}`),
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
			Body:   []byte(`{"data":[{"iface":"vmbr0","type":"bridge","active":1,"exists":1,"method":"static","families":["inet"],"bridge-ports":"eno1"}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/disks/list"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"devpath":"/dev/sda","model":"Test SSD","type":"ssd","size":1024,"health":"PASSED"}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/ceph/status"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"health":{"status":"HEALTH_WARN"},"fsid":"ceph-test"}}`),
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
	case strings.HasSuffix(req.URL, "/api2/json/cluster/resources?type=vm"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"id":"qemu/100","node":"pve-a","name":"vm-100","type":"qemu","status":"running","vmid":100,"cpu":0.1,"maxcpu":4,"mem":512,"maxmem":2048,"disk":1024,"maxdisk":4096}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/status/current"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"status":"running","cpu":0.1,"mem":512,"maxmem":2048}}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu/100/config"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":{"name":"vm-100","cores":4,"memory":2048,"api_token":"should-not-leak","net0":"virtio=00:11:22:33:44:55"}}`),
		}, nil
	default:
		return &sdk.HTTPResponse{Status: http.StatusNotFound, Body: []byte(`{}`)}, nil
	}
}

func TestRunProxmoxCheckBuildsDiscovery(t *testing.T) {
	client := &fakeHTTPClient{}
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = client
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	result, err := runProxmoxCheck(Config{
		BaseURL:       "https://pve-a.example:8006/",
		APIToken:      "PVEAPIToken=root@pam!sr=test-token",
		IncludeGuests: boolPtr(true),
	})
	if err != nil {
		t.Fatalf("runProxmoxCheck() error = %v", err)
	}

	if result.Status != sdk.StatusWarning {
		t.Fatalf("unexpected status: %s", result.Status)
	}
	if len(result.DeviceDiscovery) != 1 {
		t.Fatalf("expected one discovery envelope, got %d", len(result.DeviceDiscovery))
	}
	if got := len(result.DeviceDiscovery[0].Devices); got != 2 {
		t.Fatalf("expected node and guest discoveries, got %d", got)
	}
	if result.DeviceDiscovery[0].Devices[0].DeviceID != "proxmox:pve:pve-a" {
		t.Fatalf("unexpected node device id: %s", result.DeviceDiscovery[0].Devices[0].DeviceID)
	}
	if result.DeviceDiscovery[0].Devices[1].DeviceID != "proxmox:qemu:100" {
		t.Fatalf("unexpected guest device id: %s", result.DeviceDiscovery[0].Devices[1].DeviceID)
	}
	if len(client.requests) != 14 {
		t.Fatalf("expected fourteen Proxmox API requests, got %d", len(client.requests))
	}
	if client.requests[0].Headers["Authorization"] != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("authorization header was not set")
	}

	var details proxmoxDetails
	if err := json.Unmarshal([]byte(result.Details), &details); err != nil {
		t.Fatalf("decode details: %v", err)
	}
	if details.Summary.Nodes != 1 || details.Summary.Guests != 1 {
		t.Fatalf("unexpected details summary: %#v", details.Summary)
	}
	if details.Targets[0].Version == nil || details.Targets[0].Version.Version != "8.2.4" {
		t.Fatalf("expected version details, got %#v", details.Targets[0].Version)
	}
	if len(details.Targets[0].Cluster) != 2 {
		t.Fatalf("expected cluster status details, got %#v", details.Targets[0].Cluster)
	}
	if details.Targets[0].Nodes[0].RuntimeState["wait"] != 0.01 {
		t.Fatalf("expected node runtime status, got %#v", details.Targets[0].Nodes[0].RuntimeState)
	}
	if details.Summary.Storage != 1 || details.Summary.NetworkInterfaces != 1 || details.Summary.Disks != 1 || details.Summary.CephEnabledNodes != 1 {
		t.Fatalf("expected infrastructure summary counts, got %#v", details.Summary)
	}
	if details.ResourceSummary.MaxNodeStorageRatio != 0.5 || details.ResourceSummary.CephWarnNodes != 1 {
		t.Fatalf("expected infrastructure resource summary, got %#v", details.ResourceSummary)
	}
	if len(details.Targets[0].Nodes[0].Storage) != 1 || details.Targets[0].Nodes[0].Storage[0].Storage != "local-zfs" {
		t.Fatalf("expected node storage details, got %#v", details.Targets[0].Nodes[0].Storage)
	}
	if len(details.Targets[0].Nodes[0].Network) != 1 || details.Targets[0].Nodes[0].Network[0].Iface != "vmbr0" {
		t.Fatalf("expected node network details, got %#v", details.Targets[0].Nodes[0].Network)
	}
	if len(details.Targets[0].Nodes[0].Disks) != 1 || details.Targets[0].Nodes[0].Disks[0].DevPath != "/dev/sda" {
		t.Fatalf("expected node disk details, got %#v", details.Targets[0].Nodes[0].Disks)
	}
	if details.Targets[0].Nodes[0].Ceph == nil || details.Targets[0].Nodes[0].Ceph.Health != "HEALTH_WARN" {
		t.Fatalf("expected node ceph details, got %#v", details.Targets[0].Nodes[0].Ceph)
	}
	if details.Targets[0].Guests[0].Config["api_token"] != "REDACTED" {
		t.Fatalf("expected guest config token redaction, got %#v", details.Targets[0].Guests[0].Config)
	}
	if len(result.Metrics) < 14 {
		t.Fatalf("expected aggregate resource metrics, got %#v", result.Metrics)
	}
	if len(result.Events) < 1 {
		t.Fatalf("expected Ceph warning event, got %#v", result.Events)
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
			"api_token":      "PVEAPIToken=root@pam!sr=test-token",
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
	if cfg.Targets[0].APIToken != "PVEAPIToken=root@pam!sr=test-token" {
		t.Fatalf("expected template token on generated target")
	}
	if cfg.Targets[0].DeviceID != "sr:device:1" || cfg.Targets[0].Partition != "dc-a" {
		t.Fatalf("unexpected first target metadata: %#v", cfg.Targets[0])
	}
	if cfg.Targets[1].BaseURL != "https://pve-b.example:8006" {
		t.Fatalf("unexpected second target URL: %s", cfg.Targets[1].BaseURL)
	}
}

func TestAddNodeDiscoveriesOnlyUsesTargetDeviceIDForMatchingNode(t *testing.T) {
	discovery := sdk.NewDeviceDiscovery(discoverySource)

	addNodeDiscoveries(discovery, Target{
		BaseURL:  "https://pve-a.example:8006",
		DeviceID: "sr:device:pve-a",
		Hostname: "pve-a.example",
	}, []proxmoxNode{
		{Node: "pve-a", Status: "online"},
		{Node: "pve-b", Status: "online"},
	})

	if got := discovery.Devices[0].DeviceID; got != "sr:device:pve-a" {
		t.Fatalf("expected matching node to keep target device ID, got %s", got)
	}
	if got := discovery.Devices[1].DeviceID; got != "proxmox:pve:pve-b" {
		t.Fatalf("expected non-target cluster node to get stable Proxmox ID, got %s", got)
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
