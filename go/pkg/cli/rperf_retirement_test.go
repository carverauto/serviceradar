package cli

import (
	"strings"
	"testing"
)

const retiredRperfChecker = "rperf-checker"

func TestRetiredRPerfCheckerRemovedFromCLI(t *testing.T) {
	if isGRPCService(retiredRperfChecker) {
		t.Fatalf("expected rperf-checker not to be registered as a gRPC service")
	}
	if !isGRPCService("snmp") || !isGRPCService("sysmon") {
		t.Fatalf("expected snmp and sysmon to remain registered as gRPC services")
	}

	for _, input := range []string{"rperf", "rperf-service", "perf"} {
		if got := normalizeServiceType(input); got == retiredRperfChecker {
			t.Fatalf("normalizeServiceType(%q) returned retired rperf-checker", input)
		}
	}

	for svc, port := range getDefaultPorts() {
		if svc == retiredRperfChecker || port == ":50081" {
			t.Fatalf("unexpected retired rperf default port entry: %s=%s", svc, port)
		}
	}

	updated, added := addStandardCheckers(AgentConfig{}, "192.0.2.10")
	if added == 0 {
		t.Fatalf("expected standard checkers to be added")
	}
	for _, chk := range updated.Checks {
		if chk.ServiceName == retiredRperfChecker || strings.Contains(chk.Details, ":50081") {
			t.Fatalf("unexpected retired rperf checker in standard checkers: %+v", chk)
		}
	}

	for _, component := range defaultServices() {
		if component == "rperf" || component == retiredRperfChecker {
			t.Fatalf("defaultServices() still contains retired component %q", component)
		}
	}

	for _, component := range selectComponents(&CmdConfig{}) {
		if component == "rperf" || component == retiredRperfChecker {
			t.Fatalf("selectComponents() still contains retired component %q", component)
		}
	}

	helpOutput := captureStdout(t, ShowHelp)
	if strings.Contains(helpOutput, retiredRperfChecker) {
		t.Fatalf("expected ShowHelp not to advertise rperf-checker, got %q", helpOutput)
	}
}
