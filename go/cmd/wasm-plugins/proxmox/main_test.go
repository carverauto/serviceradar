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
	case strings.HasSuffix(req.URL, "/api2/json/nodes"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"node":"pve-a","status":"online","cpu":0.25,"maxcpu":16,"mem":1024,"maxmem":4096,"uptime":3600}]}`),
		}, nil
	case strings.HasSuffix(req.URL, "/api2/json/cluster/resources?type=vm"):
		return &sdk.HTTPResponse{
			Status: http.StatusOK,
			Body:   []byte(`{"data":[{"id":"qemu/100","node":"pve-a","name":"vm-100","type":"qemu","status":"running","vmid":100,"cpu":0.1,"maxcpu":4,"mem":512,"maxmem":2048}]}`),
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

	if result.Status != sdk.StatusOK {
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
	if len(client.requests) != 2 {
		t.Fatalf("expected two Proxmox API requests, got %d", len(client.requests))
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
}

func boolPtr(value bool) *bool {
	return &value
}

func TestRunProxmoxCheckRequiresTargetAndToken(t *testing.T) {
	if _, err := runProxmoxCheck(Config{APIToken: "token"}); err != errMissingTarget {
		t.Fatalf("expected missing target, got %v", err)
	}

	if _, err := runProxmoxCheck(Config{BaseURL: "https://pve.example:8006"}); err == nil || !strings.Contains(err.Error(), errMissingToken.Error()) {
		t.Fatalf("expected missing token, got %v", err)
	}
}
