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
		"ExecStartPre=+/usr/bin/install -d -o serviceradar -g serviceradar -m 0750 /run/serviceradar /run/serviceradar/netprobe /var/lib/serviceradar/netprobe",
		"ExecStartPre=+/usr/bin/install -d -o root -g root -m 0700 /sys/fs/bpf/serviceradar /sys/fs/bpf/serviceradar/netprobe",
		"/sys/fs/bpf/flow_events",
		"/sys/fs/bpf/serviceradar/netprobe/flow_events",
		"AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON",
		"CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON CAP_SETUID CAP_SETGID",
		"ReadWritePaths=/run/serviceradar /var/lib/serviceradar /sys/fs/bpf",
	}
	for _, want := range mustContain {
		if !strings.Contains(unit, want) {
			t.Fatalf("netprobe unit missing %q", want)
		}
	}

	if strings.Contains(unit, "\nUser=serviceradar\n") {
		t.Fatal("netprobe unit must not start directly as User=serviceradar; it must load eBPF as root and then --drop-user")
	}
}
