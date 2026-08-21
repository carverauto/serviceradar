package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestNetprobeSystemdUnitStagedPathContract pins the coupling between the shipped
// systemd unit (addons/netprobe/serviceradar-netprobe.service) and the agent's add-on
// staging layout. The root-owned agent-updater installs the unit VERBATIM
// (InstallAddonSystemdUnits copies the file with no ExecStart templating), so the unit's
// ExecStart must hardcode the exact path where the activation runtime stages the binary.
// If the staging layout changes, this test fails and the shipped unit's ExecStart must be
// updated in lockstep.
func TestNetprobeSystemdUnitStagedPathContract(t *testing.T) {
	const (
		netprobeAddonID    = "netprobe"
		netprobeBinaryName = "serviceradar-netprobe"
		netprobeEbpfObject = "netprobe_ebpf.o"
		// Must equal the corresponding paths in ExecStart= of
		// addons/netprobe/serviceradar-netprobe.service (the binary and the --ebpf-object,
		// both shipped flat in the bundle and staged under current/).
		wantStagedBinary = "/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe"
		wantStagedEbpf   = "/var/lib/serviceradar/agent/addons/netprobe/current/netprobe_ebpf.o"
	)

	currentDir := filepath.Join(resolveAddonArtifactRoot(""), netprobeAddonID, addonCurrentLink)

	if got := filepath.Join(currentDir, netprobeBinaryName); got != wantStagedBinary {
		t.Fatalf(
			"netprobe staged binary path = %q, want %q.\n"+
				"The verbatim-installed serviceradar-netprobe.service ExecStart must match this path; "+
				"update the unit and this test together.",
			got, wantStagedBinary,
		)
	}

	if got := filepath.Join(currentDir, netprobeEbpfObject); got != wantStagedEbpf {
		t.Fatalf(
			"netprobe staged eBPF object path = %q, want %q.\n"+
				"The unit's --ebpf-object (and the bundle data_entry) must match this staged path; "+
				"update the unit, the bundle, and this test together.",
			got, wantStagedEbpf,
		)
	}
}

func TestNetprobeSystemdUnitPrivilegedStartupContract(t *testing.T) {
	unitBytes, err := os.ReadFile(filepath.Join("..", "..", "..", "addons", "netprobe", "serviceradar-netprobe.service"))
	if err != nil {
		t.Fatalf("read netprobe unit: %v", err)
	}
	unit := string(unitBytes)

	mustContain := []string{
		"Group=serviceradar",
		"--drop-user serviceradar",
		"ExecStartPre=+/bin/sh -c '/usr/bin/chcon -t bin_t /var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe >/dev/null 2>&1 || true'",
		"ExecStartPre=+/usr/bin/install -d -o serviceradar -g serviceradar -m 0750 /run/serviceradar /run/serviceradar/netprobe /var/lib/serviceradar/netprobe",
		"ExecStartPre=+/usr/bin/install -d -o root -g root -m 0700 /sys/fs/bpf/serviceradar /sys/fs/bpf/serviceradar/netprobe",
		"/sys/fs/bpf/flow_events",
		"/sys/fs/bpf/socket_to_pid",
		"/sys/fs/bpf/serviceradar/netprobe/flow_events",
		"/sys/fs/bpf/serviceradar/netprobe/socket_to_pid",
		"AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON",
		"CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON CAP_SETUID CAP_SETGID",
		"ReadWritePaths=/run/serviceradar /run/serviceradar/netprobe /var/lib/serviceradar /var/lib/serviceradar/netprobe /sys/fs/bpf",
		"Slice=serviceradar.slice",
	}
	for _, want := range mustContain {
		if !strings.Contains(unit, want) {
			t.Fatalf("netprobe unit missing %q", want)
		}
	}

	if strings.Contains(unit, "\nUser=serviceradar\n") {
		t.Fatal("netprobe unit must not start directly as User=serviceradar; it must load eBPF as root and then --drop-user")
	}
	if strings.Contains(unit, "\nRuntimeDirectory=") || strings.Contains(unit, "\nStateDirectory=") {
		t.Fatal("netprobe unit must use explicit root ExecStartPre directory setup; systemd RuntimeDirectory/StateDirectory blocked IPC bind after --drop-user")
	}
}

func TestAgentSystemdUnitDoesNotOwnSharedRuntimeDirectory(t *testing.T) {
	unitBytes, err := os.ReadFile(filepath.Join("..", "..", "..", "build", "packaging", "agent", "systemd", "serviceradar-agent.service"))
	if err != nil {
		t.Fatalf("read agent unit: %v", err)
	}
	unit := string(unitBytes)

	if strings.Contains(unit, "\nRuntimeDirectory=serviceradar\n") {
		t.Fatal("agent unit must not own /run/serviceradar as RuntimeDirectory; restarting the agent can remove netprobe's IPC socket")
	}
	if strings.Contains(unit, "\nRuntimeDirectoryMode=0700\n") {
		t.Fatal("agent unit must not force /run/serviceradar to 0700; netprobe and agent share the runtime tree")
	}

	want := "ExecStartPre=+/usr/bin/install -d -o serviceradar -g serviceradar -m 0750 /run/serviceradar"
	if !strings.Contains(unit, want) {
		t.Fatalf("agent unit missing explicit shared runtime directory setup %q", want)
	}

	if !strings.Contains(unit, "\nSlice=serviceradar.slice\n") {
		t.Fatal("agent unit must join serviceradar.slice for ServiceRadar host-component cgroup accounting")
	}
	if !strings.Contains(unit, "\nDelegate=yes\n") {
		t.Fatal("agent unit must delegate its cgroup so native add-on limits can be enforced")
	}
	if strings.Contains(unit, "\nDelegateSubgroup=") {
		t.Fatal("agent unit must remain compatible with enterprise systemd releases before DelegateSubgroup")
	}

	wantCaps := "CapabilityBoundingSet=CAP_NET_RAW CAP_SETFCAP CAP_DAC_OVERRIDE CAP_FOWNER CAP_CHOWN CAP_MAC_ADMIN"
	if !strings.Contains(unit, wantCaps) {
		t.Fatalf("agent unit missing updater SELinux relabel capability %q", wantCaps)
	}
}

func TestHostComponentSystemdUnitsShareSliceWithoutAgentParentage(t *testing.T) {
	units := map[string]string{
		"agent": filepath.Join("..", "..", "..", "build", "packaging", "agent", "systemd", "serviceradar-agent.service"),
		"netprobe": filepath.Join(
			"..",
			"..",
			"..",
			"addons",
			"netprobe",
			"serviceradar-netprobe.service",
		),
		"bumblebee": filepath.Join(
			"..",
			"..",
			"..",
			"addons",
			"bumblebee-scan",
			"serviceradar-bumblebee-scan.service",
		),
		"scalibr-endpoint-inventory": filepath.Join(
			"..",
			"..",
			"..",
			"addons",
			"scalibr-endpoint-inventory",
			"serviceradar-scalibr-endpoint-inventory.service",
		),
	}

	for name, unitPath := range units {
		unitBytes, err := os.ReadFile(unitPath)
		if err != nil {
			t.Fatalf("read %s unit: %v", name, err)
		}
		unit := string(unitBytes)

		if !strings.Contains(unit, "\nSlice=serviceradar.slice\n") {
			t.Fatalf("%s unit must join serviceradar.slice", name)
		}

		for _, forbidden := range []string{
			"\nPartOf=serviceradar-agent.service\n",
			"\nBindsTo=serviceradar-agent.service\n",
			"\nRequires=serviceradar-agent.service\n",
		} {
			if strings.Contains(unit, forbidden) {
				t.Fatalf("%s unit must not make privileged add-ons process children/dependents of serviceradar-agent.service via %q", name, strings.TrimSpace(forbidden))
			}
		}
	}
}
