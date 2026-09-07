package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
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
			Body:   []byte(`{"data":{"port":5901,"ticket":"__SERVICERADAR_HOST_PROXMOX_TICKET__"}}`),
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

type inventoryHTTPFunc func(sdk.HTTPRequest) (*sdk.HTTPResponse, error)

func (f inventoryHTTPFunc) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	return f(req)
}

func TestInventorySubmitsAllHostsBeforeGuests(t *testing.T) {
	oldHTTP, oldSubmit := proxmoxHTTP, submitResult
	t.Cleanup(func() { proxmoxHTTP, submitResult = oldHTTP, oldSubmit })
	var batches []proxmoxDetails
	proxmoxHTTP = inventoryHTTPFunc(func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		if strings.Contains(req.URL, "/qemu") || strings.Contains(req.URL, "/lxc") {
			if len(batches) == 0 || len(batches[0].Targets[0].Nodes) != 2 || len(batches[0].Targets[0].Guests) != 0 {
				t.Fatalf("all hosts must be submitted before guest request %s: %#v", req.URL, batches)
			}
			hosts := batches[0].Targets[0].Nodes
			if hosts[0].Node != "host01" || hosts[1].Node != "host02" {
				t.Fatalf("initial batch must contain both hosts: %#v", hosts)
			}
		}
		body := `{"data":[]}`
		switch {
		case strings.HasSuffix(req.URL, "/version"):
			body = `{"data":{"version":"1.0-example"}}`
		case strings.HasSuffix(req.URL, "/nodes"):
			body = `{"data":[{"node":"host01","status":"online"},{"node":"host02","status":"online"}]}`
		case strings.HasSuffix(req.URL, "/host01/network"):
			body = `{"data":[{"iface":"vmbr0","address":"192.0.2.41","cidr":"192.0.2.41/24"}]}`
		case strings.HasSuffix(req.URL, "/host01/qemu"):
			body = `{"data":[{"vmid":501,"name":"guest01","status":"stopped"}]}`
		case strings.HasSuffix(req.URL, "/501/config"):
			body = `{"data":{"net0":"virtio=00:00:5e:00:53:41,ip=192.0.2.42/24"}}`
		}
		return &sdk.HTTPResponse{Status: http.StatusOK, Body: []byte(body)}, nil
	})
	submitResult = func(result *pluginResult) error {
		var batch proxmoxDetails
		if err := json.Unmarshal([]byte(result.Details), &batch); err != nil {
			t.Fatal(err)
		}
		batches = append(batches, batch)
		return nil
	}
	result, err := runProxmoxCheck(Config{
		BaseURL:       "https://controller.example.com:8006",
		APIToken:      hostCredentialSentinel,
		IncludeGuests: boolPtr(true),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(batches) != 2 {
		t.Fatalf("expected all hosts followed by one guest batch, got %d", len(batches))
	}
	first := batches[1].Targets[0]
	if len(first.Nodes) != 1 || len(first.Guests) != 1 || first.Guests[0].Node != first.Nodes[0].Node {
		t.Fatalf("batch must contain guest and owner: %#v", first)
	}
	if first.Nodes[0].IP != "192.0.2.41" {
		t.Fatalf("standalone host lost network IP: %q", first.Nodes[0].IP)
	}
	var counted checkSummary
	for _, batch := range batches {
		accumulateSummary(&counted, batch.Summary)
	}
	if counted.Nodes != 2 || counted.Guests != 1 || counted.NetworkInterfaces != 1 {
		t.Fatalf("owning host must not be counted twice: %#v", counted)
	}
	if batches[1].Summary.Nodes != 0 || batches[1].ResourceSummary.NetworkInterfaceCount != 0 {
		t.Fatalf("guest batch must count only guest resources: %#v", batches[1])
	}
	if !strings.Contains(result.Summary, "2 node(s), 1 guest(s)") {
		t.Fatalf("unexpected totals: %s", result.Summary)
	}
}

func TestInventorySubmissionFailureStopsExecution(t *testing.T) {
	oldHTTP, oldSubmit := proxmoxHTTP, submitResult
	t.Cleanup(func() { proxmoxHTTP, submitResult = oldHTTP, oldSubmit })
	proxmoxHTTP = staticHTTPClient{response: &sdk.HTTPResponse{Status: http.StatusOK,
		Body: []byte(`{"data":[{"node":"host01"}]}`)}}
	submitErr := errors.New("inventory queue unavailable")
	calls := 0
	submitResult = func(*pluginResult) error {
		calls++
		return submitErr
	}
	result, err := runProxmoxCheck(Config{BaseURL: "https://controller.example.com:8006",
		APIToken: hostCredentialSentinel, IncludeGuests: boolPtr(false)})
	if result != nil || !errors.Is(err, submitErr) || calls != 1 {
		t.Fatalf("submission failure must fail the run: result=%v err=%v calls=%d", result, err, calls)
	}
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
		APIToken:      hostCredentialSentinel,
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
	if client.requests[0].Headers["Authorization"] != hostCredentialSentinel {
		t.Fatalf("authorization header was not set")
	}
	if len(batches) != 2 {
		t.Fatalf("expected an early host batch and a self-contained guest batch, got %d", len(batches))
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
		if len(tgt.Guests) > 0 {
			g := tgt
			guestDetails = &g
			for _, disc := range b.DeviceDiscovery {
				for _, dev := range disc.Devices {
					if dev.IP != "" {
						guestDiscoveryIP = dev.IP
					}
				}
			}
		}
		if len(tgt.Nodes) > 0 && nodeDetails == nil {
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

	cfg := Config{BaseURL: "https://pve-a.example:8006", APIToken: hostCredentialSentinel}
	cfg.applyDefaults()

	warnings := map[string]string{}
	guestResources := fetchGuests(
		cfg,
		Target{BaseURL: cfg.BaseURL},
		cfg.APIToken,
		[]proxmoxNode{{Node: "pve-a", Status: "online"}},
		warnings,
	)
	guests := enrichGuests(cfg, Target{BaseURL: cfg.BaseURL}, cfg.APIToken, guestResources, time.Time{}, warnings)

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
	err := getJSON(Config{TimeoutMS: defaultTimeoutMS}, Target{BaseURL: "https://pve.example:8006"}, hostCredentialSentinel, "/api2/json/test", &out)
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

func TestRunProxmoxCheckRejectsRawAPITokenMaterial(t *testing.T) {
	client := &fakeHTTPClient{}
	oldHTTP := proxmoxHTTP
	proxmoxHTTP = client
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	includeGuests := false
	_, err := runProxmoxCheck(Config{
		BaseURL:       "https://pve-a.example:8006/",
		APIToken:      "root@pam!sr=test-token",
		IncludeGuests: &includeGuests,
	})
	if err == nil || !strings.Contains(err.Error(), errMissingToken.Error()) {
		t.Fatalf("raw token error = %v, want fail-closed missing-token result", err)
	}
	if len(client.requests) != 0 {
		t.Fatalf("raw token caused %d network requests", len(client.requests))
	}
}

func boolPtr(value bool) *bool {
	return &value
}

func TestConfigFromMapRejectsBrokerGrant(t *testing.T) {
	_, err := configFromMap(map[string]any{
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
	if err == nil {
		t.Fatal("Wasm config accepted a credential broker grant")
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
			"api_token": "__SERVICERADAR_HOST_CREDENTIAL__",
			"include_guests": true,
			"timeout_ms": 45000
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
	if cfg.APIToken != hostCredentialSentinel {
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

func TestConfigFromMapAppliesHostSentinelToPluginInputTargets(t *testing.T) {
	cfg, err := configFromMap(map[string]any{
		"schema":         sdk.PluginInputsSchemaV1,
		"policy_id":      "policy-1",
		"policy_version": 1,
		"agent_id":       "agent-1",
		"generated_at":   "2026-05-06T19:00:00Z",
		"template": map[string]any{
			"api_token": hostCredentialSentinel,
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

	if cfg.APIToken != hostCredentialSentinel {
		t.Fatalf("expected host credential sentinel to be applied")
	}
	if len(cfg.Targets) != 1 {
		t.Fatalf("expected one target, got %d", len(cfg.Targets))
	}
	if cfg.Targets[0].APIToken != hostCredentialSentinel {
		t.Fatalf("expected host credential sentinel to be inherited by generated target")
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
	}, nil, nil)

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

func TestConfigSchemaExposesNoCredentialOrTLSBypassInputs(t *testing.T) {
	raw, err := os.ReadFile("config.schema.json")
	if err != nil {
		t.Fatalf("read schema: %v", err)
	}

	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("decode schema: %v", err)
	}

	properties := schema["properties"].(map[string]any)
	if schema["additionalProperties"] != false {
		t.Fatal("published inventory schema must reject undeclared authority fields")
	}
	allowed := map[string]struct{}{
		"timeout_ms": {}, "max_response_bytes": {}, "max_guests": {}, "include_guests": {},
	}
	if len(properties) != len(allowed) {
		t.Fatalf("published inventory schema properties = %#v, want bounded presentation settings only", properties)
	}
	for key := range properties {
		if _, ok := allowed[key]; !ok {
			t.Fatalf("published inventory schema exposes authority-bearing field %q", key)
		}
	}
}

func TestConsoleConfigSchemaExposesNoCredentialOrTLSBypassInputs(t *testing.T) {
	raw, err := os.ReadFile("config.console.schema.json")
	if err != nil {
		t.Fatalf("read console schema: %v", err)
	}
	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("decode console schema: %v", err)
	}
	properties := schema["properties"].(map[string]any)
	if schema["additionalProperties"] != false {
		t.Fatal("published console schema must reject undeclared authority fields")
	}
	if len(properties) != 1 || properties["timeout_ms"] == nil {
		t.Fatalf("published console schema properties = %#v, want timeout_ms only", properties)
	}
}

func TestValidateConsoleConfigUsesHostCredentialSentinelWithoutBrokerGrant(t *testing.T) {
	cfg := consoleConfig{
		CredentialRuleID: "rule-1",
		APIToken:         hostCredentialSentinel,
		Console: consoleContext{
			SessionID:          "session-1",
			ConsoleMode:        "proxmox_termproxy",
			CredentialRuleID:   "rule-1",
			PluginAssignmentID: "assignment-1",
		},
		Target:    consoleTarget{Hostname: "pve.example"},
		TimeoutMS: defaultTimeoutMS,
	}

	if err := validateConsoleConfig(cfg); err != nil {
		t.Fatalf("validateConsoleConfig returned error: %v", err)
	}
	if got := normalizeProxmoxAPIToken(cfg.APIToken); got != hostCredentialSentinel {
		t.Fatalf("normalized sentinel = %q, want exact host sentinel", got)
	}

	cfg.CredentialRuleID = ""
	if err := validateConsoleConfig(cfg); err == nil || !strings.Contains(err.Error(), "credential_rule_id") {
		t.Fatalf("expected credential_rule_id validation error, got %v", err)
	}
}

func TestResolveProxmoxConsoleTargetSupportsSourceScopedV3Identity(t *testing.T) {
	cfg := consoleConfig{
		Console: consoleContext{TargetKind: "qemu_guest"},
		Target: consoleTarget{
			ProviderRef:    "proxmox:v3:provider-1:controller-1:farm%3A01:qemu:101",
			Cluster:        "farm:01",
			Node:           "pve01",
			VMID:           101,
			TargetKind:     "qemu_guest",
			ControllerID:   "controller-1",
			NativeObjectID: "101",
		},
	}

	target, err := resolveProxmoxConsoleTarget(cfg)
	if err != nil {
		t.Fatalf("resolveProxmoxConsoleTarget returned error: %v", err)
	}
	if target.Cluster != "farm:01" || target.Node != "pve01" || target.VMID != 101 ||
		target.TargetKind != "qemu_guest" {
		t.Fatalf("unexpected v3 console target: %#v", target)
	}

	cfg.Target.Node = ""
	if _, err := resolveProxmoxConsoleTarget(cfg); err == nil || !strings.Contains(err.Error(), "node") {
		t.Fatalf("v3 guest without explicit owner node returned %v", err)
	}

	cfg.Target.Node = "pve01"
	cfg.Target.VMID = 102
	if _, err := resolveProxmoxConsoleTarget(cfg); err == nil || !strings.Contains(err.Error(), "vmid") {
		t.Fatalf("mismatched v3 vmid returned %v", err)
	}
}

func TestProxmoxManifestsGrantNoStaticDomainAuthority(t *testing.T) {
	for _, path := range []string{"plugin.yaml", "plugin.console.yaml"} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		manifest := string(raw)
		if !strings.Contains(manifest, "allowed_domains: []") || strings.Contains(manifest, `"*"`) {
			t.Fatalf("%s must grant no static domain wildcard authority", path)
		}
	}
}

func TestConsoleConfigRejectsLegacyCredentialAndTransportAuthority(t *testing.T) {
	tests := map[string]map[string]any{
		"raw ssh object":            {"ssh": map[string]any{"username": "root", "password": "secret"}},
		"raw credential object":     {"credential_secret": map[string]any{"username": "root", "password": "secret"}},
		"raw credential string":     {"credential_secret": "secret"},
		"raw api token":             {"api_token": "PVEAPIToken=user@pve!token=secret"},
		"TLS verification bypass":   {"insecure_skip_verify": true},
		"SSH verification bypass":   {"ssh_host_key_policy": "skip_verify"},
		"private key in nested map": {"nested": map[string]any{"private_key": "secret"}},
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := consoleConfigFromMap(raw); err == nil {
				t.Fatal("legacy authority-bearing console config was accepted")
			}
		})
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
			"credential_rule_id": "rule-1",
			"credential_secret":  hostCredentialSentinel,
		},
		"console": map[string]any{
			"session_id":           "session-1",
			"device_uid":           "device-b",
			"credential_rule_id":   "rule-1",
			"plugin_assignment_id": "assignment-1",
			"console_mode":         "ssh",
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
		HostCredential:   hostCredentialSentinel,
		Console: consoleContext{
			SessionID:          "session-1",
			ConsoleMode:        "ssh",
			CredentialRuleID:   "rule-1",
			PluginAssignmentID: "assignment-1",
			Cols:               80,
			Rows:               24,
		},
		Target:    consoleTarget{Hostname: "pve.example"},
		TimeoutMS: defaultTimeoutMS,
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
		CredentialRuleID: "rule-1",
		APIToken:         hostCredentialSentinel,
		Console: consoleContext{
			SessionID:          "session-1",
			ConsoleMode:        "proxmox_termproxy",
			TargetKind:         "pve_host",
			CredentialRuleID:   "rule-1",
			PluginAssignmentID: "assignment-1",
		},
		Target:    consoleTarget{BaseURL: "https://pve.example:8006", ProviderRef: "proxmox:node:pve-a"},
		TimeoutMS: defaultTimeoutMS,
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
	if got := client.requests[0].Headers["Authorization"]; got != hostCredentialSentinel {
		t.Fatalf("unexpected Authorization header %q", got)
	}
	if !strings.HasPrefix(ws.url, "wss://pve.example:8006/api2/json/nodes/pve-a/vncwebsocket?") {
		t.Fatalf("unexpected websocket URL %q", ws.url)
	}
	if ws.headers["Authorization"] != hostCredentialSentinel {
		t.Fatalf("unexpected websocket Authorization header %q", ws.headers["Authorization"])
	}
	if ws.insecureSkipVerify || client.requests[0].InsecureSkipVerify {
		t.Fatal("Proxmox native console requested a TLS verification bypass")
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
		"1":                       true,
		"1,fstrim_cloned_disks=1": true,
		"enabled=1,type=virtio":   true,
		"0":                       false,
		"":                        false,
		"enabled=0":               false,
	}
	for raw, want := range cases {
		if got := guestAgentEnabled(map[string]string{"agent": raw}); got != want {
			t.Fatalf("guestAgentEnabled(%q) = %v, want %v", raw, got, want)
		}
	}
}
