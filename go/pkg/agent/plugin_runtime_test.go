package agent

import (
	"encoding/json"
	"net/netip"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

const unknownStatus = "UNKNOWN"

func TestAdmitAssignmentsEnforcesLimits(t *testing.T) {
	mgr := &PluginManager{logger: logger.NewTestLogger()}

	assignments := []*pluginAssignment{
		{
			AssignmentID: "a",
			Resources: pluginResources{
				RequestedMemoryMB:  60,
				RequestedCPUMS:     100,
				MaxOpenConnections: 1,
			},
		},
		{
			AssignmentID: "b",
			Resources: pluginResources{
				RequestedMemoryMB:  50,
				RequestedCPUMS:     100,
				MaxOpenConnections: 1,
			},
		},
		{
			AssignmentID: "c",
			Resources: pluginResources{
				RequestedMemoryMB:  10,
				RequestedCPUMS:     100,
				MaxOpenConnections: 1,
			},
		},
	}

	limits := pluginEngineLimits{
		MaxMemoryMB:        100,
		MaxCPUMS:           300,
		MaxConcurrent:      2,
		MaxOpenConnections: 2,
	}

	admitted, rejected, usage := mgr.admitAssignments(assignments, limits)

	if len(admitted) != 2 {
		t.Fatalf("expected 2 admitted assignments, got %d", len(admitted))
	}
	if len(rejected) != 1 {
		t.Fatalf("expected 1 rejected assignment, got %d", len(rejected))
	}
	if rejected[0].AssignmentID != "b" {
		t.Fatalf("expected assignment b to be rejected, got %s", rejected[0].AssignmentID)
	}

	if usage.memoryMB != 70 || usage.cpuMS != 200 || usage.connections != 2 || usage.count != 2 {
		t.Fatalf("unexpected usage: %#v", usage)
	}
}

func TestNormalizeResources(t *testing.T) {
	res := normalizeResources(pluginResources{
		RequestedMemoryMB:  -1,
		RequestedCPUMS:     -5,
		MaxOpenConnections: -2,
	})

	if res.RequestedMemoryMB != 0 || res.RequestedCPUMS != 0 || res.MaxOpenConnections != 0 {
		t.Fatalf("expected negative resource values to be clamped to 0, got %#v", res)
	}
}

func TestNormalizePluginPayload(t *testing.T) {
	pl := &PushLoop{}
	observed := time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC)

	result := PluginResult{
		AssignmentID: "assign-1",
		PluginID:     "plugin-1",
		PluginName:   "HTTP Check",
		Payload:      []byte(`{"status":"ok","summary":"all good","labels":{"region":"iad"}}`),
		ObservedAt:   observed,
	}

	data, available, err := pl.normalizePluginPayload(result, "agent-1", "default")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !available {
		t.Fatalf("expected available=true for OK status")
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["status"] != "OK" {
		t.Fatalf("expected status OK, got %#v", payload["status"])
	}
	if payload["summary"] != "all good" {
		t.Fatalf("unexpected summary: %#v", payload["summary"])
	}
	if payload["observed_at"] != observed.Format(time.RFC3339Nano) {
		t.Fatalf("unexpected observed_at: %#v", payload["observed_at"])
	}

	labels, _ := payload["labels"].(map[string]interface{})
	if labels["region"] != "iad" {
		t.Fatalf("expected region label to be preserved")
	}
	if labels["assignment_id"] != "assign-1" {
		t.Fatalf("expected assignment_id label to be set")
	}
	if labels["plugin_id"] != "plugin-1" {
		t.Fatalf("expected plugin_id label to be set")
	}
	if labels["plugin_name"] != "HTTP Check" {
		t.Fatalf("expected plugin_name label to be set")
	}
	if labels["agent_id"] != "agent-1" {
		t.Fatalf("expected agent_id label to be set")
	}
	if labels["partition"] != "default" {
		t.Fatalf("expected partition label to be set")
	}
}

func TestNormalizePluginPayloadRejectsInvalidStatus(t *testing.T) {
	pl := &PushLoop{}
	result := PluginResult{
		Payload: []byte(`{"status":"bad","summary":"oops"}`),
	}

	_, _, err := pl.normalizePluginPayload(result, "agent-1", "default")
	if err == nil {
		t.Fatalf("expected error for invalid status")
	}
}

func TestBuildPluginErrorPayload(t *testing.T) {
	pl := &PushLoop{}
	result := PluginResult{
		AssignmentID: "assign-1",
		PluginID:     "plugin-1",
		PluginName:   "HTTP Check",
	}

	data := pl.buildPluginErrorPayload(result, nil, "agent-1", "default")
	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["status"] != unknownStatus {
		t.Fatalf("expected %s status", unknownStatus)
	}
	if _, ok := payload["summary"].(string); !ok {
		t.Fatalf("expected summary to be a string")
	}
}

func TestBuildPluginTelemetryPayload(t *testing.T) {
	snapshot := PluginEngineSnapshot{
		ObservedAt:          time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC),
		AssignmentsRejected: 1,
	}

	data, healthy := buildPluginTelemetryPayload(snapshot, "agent-1", "default")
	if healthy {
		t.Fatalf("expected unhealthy snapshot due to rejected assignments")
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["schema"] != "serviceradar.plugin_engine_telemetry.v1" {
		t.Fatalf("unexpected schema: %#v", payload["schema"])
	}

	health, _ := payload["health"].(map[string]interface{})
	if health["status"] != "degraded" {
		t.Fatalf("expected degraded health status")
	}
	if health["reason"] != "admission_denied" {
		t.Fatalf("expected admission_denied reason")
	}
}

func TestPluginPermissionsAllowsDomain(t *testing.T) {
	perms := pluginPermissions{
		AllowedDomains: []string{"example.com", "*.svc.local"},
	}
	perms.normalize()

	if !perms.allowsDomain("example.com") {
		t.Fatalf("expected exact domain to be allowed")
	}
	if !perms.allowsDomain("Example.com.") {
		t.Fatalf("expected case-insensitive domain to be allowed")
	}
	if !perms.allowsDomain("api.svc.local") {
		t.Fatalf("expected wildcard suffix to be allowed")
	}
	if perms.allowsDomain("evil.com") {
		t.Fatalf("expected unknown domain to be denied")
	}
	if perms.allowsDomain("") {
		t.Fatalf("expected empty domain to be denied")
	}

	perms = pluginPermissions{AllowedDomains: []string{"*"}}
	perms.normalize()
	if !perms.allowsDomain("anything.example") {
		t.Fatalf("expected wildcard to allow any domain")
	}
}

func TestPluginPermissionsAllowsPort(t *testing.T) {
	perms := pluginPermissions{AllowedPorts: []int{80, 443}}
	perms.normalize()

	if !perms.allowsPort(80) {
		t.Fatalf("expected port 80 to be allowed")
	}
	if perms.allowsPort(22) {
		t.Fatalf("expected port 22 to be denied")
	}

	perms = pluginPermissions{}
	perms.normalize()
	if !perms.allowsPort(22) {
		t.Fatalf("expected empty port list to allow all ports")
	}
}

func TestPluginPermissionsAllowsAddress(t *testing.T) {
	perms := pluginPermissions{
		AllowedNetworks: []string{"10.0.0.0/24", "192.168.1.10/32"},
	}
	perms.normalize()

	if !perms.allowsAddress(netip.MustParseAddr("10.0.0.5")) {
		t.Fatalf("expected address within prefix to be allowed")
	}
	if !perms.allowsAddress(netip.MustParseAddr("192.168.1.10")) {
		t.Fatalf("expected single-host prefix to be allowed")
	}
	if perms.allowsAddress(netip.MustParseAddr("10.0.1.5")) {
		t.Fatalf("expected address outside prefixes to be denied")
	}
}
