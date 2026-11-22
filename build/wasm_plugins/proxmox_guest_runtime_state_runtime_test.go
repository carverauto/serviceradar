package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// The agent's host-call error code for a request its credential grant refuses
// (pluginErrDenied in go/pkg/agent/plugin_runtime.go). An agent older than
// plugin 0.1.14 answers the QEMU guest list read with ?full=1 this way.
const proxmoxRuntimeAgentDenied = -2

const proxmoxQEMUFullPath = "/api2/json/nodes/pve-a/qemu?full=1"

// runProxmoxGuests runs the TinyGo-built plugin against the invented cluster in
// proxmoxRuntimeResponses with the given overrides, and returns the guests the
// plugin reported in its inventory details, keyed by name, plus the request
// paths in the order they were made. An override whose value is "" makes the
// host refuse that request the way an agent's credential grant does.
func runProxmoxGuests(t *testing.T, overrides map[string]string) (map[string]map[string]any, []string) {
	t.Helper()
	responses := make(map[string]string, len(proxmoxRuntimeResponses)+len(overrides))
	for k, v := range proxmoxRuntimeResponses {
		responses[k] = v
	}
	for k, v := range overrides {
		responses[k] = v
	}

	var requested []string
	host := &wasmHost{config: []byte(proxmoxRuntimeConfig), http: func(t *testing.T, request wasmHTTPRequest) (int, []byte) {
		path := strings.TrimPrefix(request.URL, "https://192.0.2.11:8006")
		requested = append(requested, path)
		body, ok := responses[path]
		if !ok || request.Method != http.MethodGet {
			t.Fatalf("unexpected HTTP request: %+v", request)
		}
		if body == "" {
			return proxmoxRuntimeAgentDenied, nil
		}
		return http.StatusOK, []byte(body)
	}}
	host.run(t, loadBuiltWasm(t, "proxmox_inventory.wasm"), "run_check")

	guests := map[string]map[string]any{}
	for _, result := range host.results {
		if result["status"] != "OK" {
			t.Fatalf("batch status %v: %v", result["status"], result["summary"])
		}
		raw, _ := result["details"].(string)
		if raw == "" {
			continue
		}
		var details struct {
			Targets []struct {
				Guests []map[string]any `json:"guests"`
			} `json:"targets"`
		}
		if err := json.Unmarshal([]byte(raw), &details); err != nil {
			t.Fatalf("result details are not JSON: %v", err)
		}
		for _, target := range details.Targets {
			for _, guest := range target.Guests {
				name, _ := guest["name"].(string)
				guests[name] = guest
			}
		}
	}
	return guests, requested
}

func requireGuest(t *testing.T, guests map[string]map[string]any, name string) map[string]any {
	t.Helper()
	guest, ok := guests[name]
	if !ok {
		t.Fatalf("no guest %q in inventory details; got %v", name, guests)
	}
	return guest
}

// Proxmox keeps status "running" for a guest whose CPUs QEMU has stopped. The
// states that stay stopped until someone acts must read as paused; the ones a
// guest passes through during start or migration must not.
func TestProxmoxInventoryReportsStoppedQEMUGuestsAsPaused(t *testing.T) {
	cases := []struct {
		qmpstatus  string
		wantStatus string
	}{
		{"io-error", "paused"},
		{"paused", "paused"},
		{"guest-panicked", "paused"},
		{"watchdog", "paused"},
		{"running", "running"},
		{"inmigrate", "running"},
		{"prelaunch", "running"},
	}
	for _, tc := range cases {
		t.Run(tc.qmpstatus, func(t *testing.T) {
			guests, _ := runProxmoxGuests(t, map[string]string{
				proxmoxQEMUFullPath: `{"data":[{"node":"pve-a","name":"vm-100","type":"qemu","status":"running","qmpstatus":"` + tc.qmpstatus + `","vmid":100,"cpu":0.1,"maxcpu":4,"mem":512,"maxmem":2048,"disk":1024,"maxdisk":4096}]}`,
			})
			vm := requireGuest(t, guests, "vm-100")
			if vm["status"] != tc.wantStatus || vm["runtime_state"] != tc.qmpstatus {
				t.Fatalf("vm-100 status=%v runtime_state=%v, want status=%s runtime_state=%s",
					vm["status"], vm["runtime_state"], tc.wantStatus, tc.qmpstatus)
			}
			ct := requireGuest(t, guests, "ct-101")
			if ct["status"] != "running" {
				t.Fatalf("ct-101 status = %v, want running", ct["status"])
			}
			if _, has := ct["runtime_state"]; has {
				t.Fatalf("ct-101 carries runtime_state %v; containers are read without full=1", ct["runtime_state"])
			}
		})
	}
}

// A 0.1.14 plugin on an agent that refuses ?full=1 must still deliver the
// inventory, and must say it could not see the running QEMU guest's state
// rather than present it as healthy.
func TestProxmoxInventoryFallsBackWhenTheAgentRefusesFullGuestList(t *testing.T) {
	guests, requested := runProxmoxGuests(t, map[string]string{
		proxmoxQEMUFullPath:                      "",
		"/api2/json/nodes/pve-a/qemu":            `{"data":[{"node":"pve-a","name":"vm-100","type":"qemu","status":"running","vmid":100,"cpu":0.1,"maxcpu":4,"mem":512,"maxmem":2048,"disk":1024,"maxdisk":4096},{"node":"pve-a","name":"vm-102","type":"qemu","status":"stopped","vmid":102,"maxcpu":2,"maxmem":1024}]}`,
		"/api2/json/nodes/pve-a/qemu/102/config": `{"data":{"name":"vm-102","cores":2,"memory":1024}}`,
	})

	vm := requireGuest(t, guests, "vm-100")
	if vm["status"] != "running" || vm["runtime_state"] != "unknown" {
		t.Fatalf("vm-100 status=%v runtime_state=%v, want running/unknown", vm["status"], vm["runtime_state"])
	}
	stopped := requireGuest(t, guests, "vm-102")
	if stopped["status"] != "stopped" {
		t.Fatalf("vm-102 status = %v, want stopped", stopped["status"])
	}
	if _, has := stopped["runtime_state"]; has {
		t.Fatalf("stopped vm-102 carries runtime_state %v", stopped["runtime_state"])
	}
	if _, has := requireGuest(t, guests, "ct-101")["runtime_state"]; has {
		t.Fatalf("ct-101 carries runtime_state after fallback")
	}

	full, plain := -1, -1
	for i, path := range requested {
		switch path {
		case proxmoxQEMUFullPath:
			full = i
		case "/api2/json/nodes/pve-a/qemu":
			plain = i
		}
	}
	if full < 0 || plain < 0 || plain < full {
		t.Fatalf("want the ?full=1 read refused and then the plain list read; requests %v", requested)
	}
}
