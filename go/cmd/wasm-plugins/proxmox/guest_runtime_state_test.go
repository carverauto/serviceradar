package main

import (
	"net/http"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// Proxmox lists a guest as running for as long as its QEMU process exists. A
// guest stopped on an I/O error (a full datastore), paused by an operator or
// panicked is still "running" in that list; only qmpstatus says otherwise.
func TestFetchNodeGuestsReportsPausedGuests(t *testing.T) {
	const fullList = `{"data":[
		{"vmid":101,"name":"vm-io-error","status":"running","qmpstatus":"io-error"},
		{"vmid":102,"name":"vm-paused","status":"running","qmpstatus":"paused"},
		{"vmid":103,"name":"vm-healthy","status":"running","qmpstatus":"running"},
		{"vmid":104,"name":"vm-migrating","status":"running","qmpstatus":"inmigrate"},
		{"vmid":105,"name":"vm-stopped","status":"stopped","qmpstatus":"stopped"}
	]}`

	guests := fetchQEMUGuests(t, func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		if strings.HasSuffix(req.URL, "/api2/json/nodes/pve-a/qemu?full=1") {
			return &sdk.HTTPResponse{Status: http.StatusOK, Body: []byte(fullList)}, nil
		}

		return &sdk.HTTPResponse{Status: http.StatusNotFound}, nil
	})

	want := map[int]struct{ status, runtime string }{
		101: {"paused", "io-error"},
		102: {"paused", "paused"},
		103: {"running", "running"},
		// A guest passing through a migration is not an outage.
		104: {"running", "inmigrate"},
		105: {"stopped", "stopped"},
	}
	if len(guests) != len(want) {
		t.Fatalf("expected %d guests, got %#v", len(want), guests)
	}
	for _, guest := range guests {
		expected := want[guest.VMID]
		if guest.Status != expected.status || guest.RuntimeState != expected.runtime {
			t.Errorf("vmid %d: status=%q runtime=%q, want status=%q runtime=%q",
				guest.VMID, guest.Status, guest.RuntimeState, expected.status, expected.runtime)
		}
	}
}

// An agent older than this plugin refuses every query string. The guest list
// must still arrive, with each running guest's runtime state marked unknown.
func TestFetchNodeGuestsFallsBackWhenTheRuntimeStateQueryIsRefused(t *testing.T) {
	var requested []string

	guests := fetchQEMUGuests(t, func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		requested = append(requested, req.URL)
		if strings.Contains(req.URL, "?") {
			return &sdk.HTTPResponse{Status: http.StatusForbidden, Body: []byte("request denied")}, nil
		}

		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"vmid":101,"name":"vm-101","status":"running"}]}`),
		}, nil
	})

	// The guest still reads as running, and says its runtime state was not read:
	// that is what lets a check report "cannot tell" instead of "healthy".
	if len(guests) != 1 || guests[0].Status != "running" || guests[0].RuntimeState != "unknown" {
		t.Fatalf("expected one running guest with an unknown runtime state, got %#v", guests)
	}
	if len(requested) != 2 || !strings.HasSuffix(requested[1], "/api2/json/nodes/pve-a/qemu") {
		t.Fatalf("expected the runtime-state read then the plain list, got %v", requested)
	}
}

// Containers have no QEMU runtime state: the list is read without the query
// and a container's status is whatever Proxmox reported.
func TestFetchNodeGuestsReadsContainersWithoutTheRuntimeStateQuery(t *testing.T) {
	oldHTTP := proxmoxHTTP
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })

	var requested []string
	proxmoxHTTP = inventoryHTTPFunc(func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
		requested = append(requested, req.URL)

		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"vmid":201,"name":"ct-201","status":"running","qmpstatus":"paused"}]}`),
		}, nil
	})

	cfg := Config{BaseURL: "https://pve-a.example.com:8006", APIToken: hostCredentialSentinel}
	cfg.applyDefaults()

	guests, err := fetchNodeGuests(cfg, Target{BaseURL: cfg.BaseURL}, cfg.APIToken, "pve-a", "lxc")
	if err != nil {
		t.Fatalf("fetch containers: %v", err)
	}
	if len(guests) != 1 || guests[0].Status != "running" {
		t.Fatalf("expected one running container, got %#v", guests)
	}
	if len(requested) != 1 || strings.Contains(requested[0], "?") {
		t.Fatalf("expected one plain container list read, got %v", requested)
	}
}

func TestGuestDetailsCarryTheRuntimeState(t *testing.T) {
	var b strings.Builder
	first := true
	appendResourceJSONFields(&b, &first, proxmoxResource{
		VMID: 101, Name: "vm-101", Status: "paused", RuntimeState: "io-error",
	})

	if got := b.String(); !strings.Contains(got, `"status":"paused"`) ||
		!strings.Contains(got, `"runtime_state":"io-error"`) {
		t.Fatalf("expected status and runtime_state in the guest details, got %s", got)
	}
}

func fetchQEMUGuests(
	t *testing.T,
	respond func(sdk.HTTPRequest) (*sdk.HTTPResponse, error),
) []proxmoxResource {
	t.Helper()

	oldHTTP := proxmoxHTTP
	t.Cleanup(func() { proxmoxHTTP = oldHTTP })
	proxmoxHTTP = inventoryHTTPFunc(respond)

	cfg := Config{BaseURL: "https://pve-a.example.com:8006", APIToken: hostCredentialSentinel}
	cfg.applyDefaults()

	guests, err := fetchNodeGuests(cfg, Target{BaseURL: cfg.BaseURL}, cfg.APIToken, "pve-a", "qemu")
	if err != nil {
		t.Fatalf("fetch guests: %v", err)
	}

	return guests
}
