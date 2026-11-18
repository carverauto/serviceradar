package cli

import (
	"strings"
	"testing"
)

func TestRetiredRPerfCheckerRemovedFromCLI(t *testing.T) {
	if isGRPCService("rperf-checker") {
		t.Fatalf("expected rperf-checker not to be registered as a gRPC service")
	}
	if !isGRPCService("snmp") || !isGRPCService("sysmon") {
		t.Fatalf("expected snmp and sysmon to remain registered as gRPC services")
	}

	for _, input := range []string{"rperf", "rperf-service", "perf"} {
		if got := normalizeServiceType(input); got == "rperf-checker" {
			t.Fatalf("normalizeServiceType(%q) returned retired rperf-checker", input)
		}
	}

	for svc, port := range getDefaultPorts() {
		if svc == "rperf-checker" || port == ":50081" {
			t.Fatalf("unexpected retired rperf default port entry: %s=%s", svc, port)
		}
	}

	updated, added := addStandardCheckers(AgentConfig{}, "192.0.2.10")
	if added == 0 {
		t.Fatalf("expected standard checkers to be added")
	}
	for _, chk := range updated.Checks {
		if chk.ServiceName == "rperf-checker" || strings.Contains(chk.Details, ":50081") {
			t.Fatalf("unexpected retired rperf checker in standard checkers: %+v", chk)
		}
	}

	for _, component := range defaultServices() {
		if component == "rperf" || component == "rperf-checker" {
			t.Fatalf("defaultServices() still contains retired component %q", component)
		}
	}

	for _, component := range selectComponents(&CmdConfig{}) {
		if component == "rperf" || component == "rperf-checker" {
			t.Fatalf("selectComponents() still contains retired component %q", component)
		}
	}

	helpOutput := captureStdout(t, ShowHelp)
	if strings.Contains(helpOutput, "rperf-checker") {
		t.Fatalf("expected ShowHelp not to advertise rperf-checker, got %q", helpOutput)
	}
}
