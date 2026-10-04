package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// An invented one-node cluster with one QEMU guest and one container. Native
// `go test` of the plugin never reaches the TinyGo-compiled encoders that run
// once a target answers, which is where the plugin died in production.
var proxmoxRuntimeResponses = map[string]string{
	"/api2/json/version":                                           `{"data":{"version":"8.2.4","release":"8.2","repoid":"0000000a"}}`,
	"/api2/json/cluster/status":                                    `{"data":[{"id":"cluster/lab","name":"lab","type":"cluster","nodes":1,"quorate":1},{"id":"node/pve-a","name":"pve-a","type":"node","online":1,"ip":"192.0.2.11"}]}`,
	"/api2/json/nodes":                                             `{"data":[{"node":"pve-a","status":"online","cpu":0.25,"maxcpu":16,"mem":1024,"maxmem":4096,"uptime":3600}]}`,
	"/api2/json/nodes/pve-a/status":                                `{"data":{"cpu":0.25,"wait":0.01,"memory":{"used":1024,"total":4096},"rootfs":{"used":2048,"total":8192}}}`,
	"/api2/json/nodes/pve-a/storage":                               `{"data":[{"storage":"local-zfs","type":"zfspool","content":"images,rootdir","active":1,"enabled":1,"used":8192,"total":16384}]}`,
	"/api2/json/nodes/pve-a/network":                               `{"data":[{"iface":"vmbr0","type":"bridge","active":1,"exists":1,"method":"static","families":["inet"],"hwaddr":"02:00:00:00:00:01","address":"192.0.2.11","cidr":"192.0.2.11/24","bridge-ports":"eno1"}]}`,
	"/api2/json/nodes/pve-a/disks/list":                            `{"data":[{"devpath":"/dev/sda","model":"Example SSD","type":"ssd","size":1024,"health":"PASSED"}]}`,
	"/api2/json/nodes/pve-a/ceph/status":                           `{"data":{"health":{"status":"HEALTH_OK"},"fsid":"00000000-0000-4000-8000-000000000000"}}`,
	"/api2/json/nodes/pve-a/qemu":                                  `{"data":[{"node":"pve-a","name":"vm-100","type":"qemu","status":"running","vmid":100,"cpu":0.1,"maxcpu":4,"mem":512,"maxmem":2048,"disk":1024,"maxdisk":4096}]}`,
	"/api2/json/nodes/pve-a/lxc":                                   `{"data":[{"node":"pve-a","name":"ct-101","type":"lxc","status":"running","vmid":101,"cpu":0.0,"maxcpu":1,"mem":64,"maxmem":512}]}`,
	"/api2/json/nodes/pve-a/qemu/100/config":                       `{"data":{"name":"vm-100","cores":4,"memory":2048,"agent":"1","net0":"virtio=02:00:00:00:01:00,bridge=vmbr0"}}`,
	"/api2/json/nodes/pve-a/qemu/100/agent/network-get-interfaces": `{"data":{"result":[{"name":"eth0","hardware-address":"02:00:00:00:01:00","ip-addresses":[{"ip-address":"192.0.2.20","ip-address-type":"ipv4","prefix":24}]}]}}`,
	"/api2/json/nodes/pve-a/qemu/100/agent/get-fsinfo":             `{"data":{"result":[{"name":"sda1","mountpoint":"/","type":"ext4","total-bytes":8192,"used-bytes":6144}]}}`,
	"/api2/json/nodes/pve-a/lxc/101/config":                        `{"data":{"hostname":"ct-101","net0":"name=eth0,bridge=vmbr0,hwaddr=02:00:00:00:02:00,ip=192.0.2.21/24"}}`,
	"/api2/json/nodes/pve-a/lxc/101/interfaces":                    `{"data":[{"name":"eth0","hwaddr":"02:00:00:00:02:00","inet":"192.0.2.21/24"}]}`,
}

const proxmoxRuntimeConfig = `{
	"schema": "serviceradar.plugin_inputs.v1",
	"policy_id": "policy-1",
	"policy_version": 1,
	"agent_id": "agent-1",
	"generated_at": "2030-01-02T03:04:05Z",
	"template": {"api_token": "__SERVICERADAR_HOST_CREDENTIAL__", "include_guests": true},
	"inputs": [{
		"name": "targets",
		"entity": "devices",
		"query": "in:devices metadata.proxmox_candidate:true",
		"chunk_index": 0,
		"chunk_total": 1,
		"chunk_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"items": [{"uid": "sr:device:1", "ip": "192.0.2.11", "hostname": "pve-a"}]
	}]
}`

func TestProxmoxInventoryRunsUnderAgentLifecycle(t *testing.T) {
	host := &wasmHost{config: []byte(proxmoxRuntimeConfig), http: func(t *testing.T, request wasmHTTPRequest) (int, []byte) {
		path := strings.TrimPrefix(request.URL, "https://192.0.2.11:8006")
		body, ok := proxmoxRuntimeResponses[path]
		if !ok || request.Method != http.MethodGet {
			t.Fatalf("unexpected HTTP request: %+v", request)
		}
		return http.StatusOK, []byte(body)
	}}
	host.run(t, loadBuiltWasm(t, "proxmox_inventory.wasm"), "run_check")

	guestIPs := map[string]bool{}
	for _, result := range host.results {
		if result["status"] != "OK" {
			t.Fatalf("batch status %v: %v", result["status"], result["summary"])
		}
		discoveries, _ := result["device_discovery"].([]any)
		for _, discovery := range discoveries {
			devices, _ := discovery.(map[string]any)["devices"].([]any)
			for _, device := range devices {
				if ip, _ := device.(map[string]any)["ip"].(string); ip != "" {
					guestIPs[ip] = true
				}
			}
		}
	}
	final := host.results[len(host.results)-1]["summary"]
	if final != "Proxmox inventory: 1 target(s), 1 node(s), 2 guest(s)" {
		t.Fatalf("final summary = %v", final)
	}
	if !guestIPs["192.0.2.20"] || !guestIPs["192.0.2.21"] {
		t.Fatalf("guest discovery missing an address: %v", guestIPs)
	}

	kinds := map[string]bool{}
	for _, raw := range host.telemetry {
		var batch struct {
			Source  map[string]any `json:"source"`
			Records []struct {
				PayloadKind string `json:"payload_kind"`
			} `json:"records"`
		}
		if err := json.Unmarshal(raw, &batch); err != nil {
			t.Fatalf("telemetry batch is not JSON: %v", err)
		}
		if batch.Source["source_type"] != "proxmox-inventory" {
			t.Fatalf("telemetry source = %v", batch.Source)
		}
		for _, record := range batch.Records {
			kinds[record.PayloadKind] = true
		}
	}
	if !kinds["serviceradar_metrics"] {
		t.Fatalf("no metric telemetry emitted; payload kinds %v", kinds)
	}
}
