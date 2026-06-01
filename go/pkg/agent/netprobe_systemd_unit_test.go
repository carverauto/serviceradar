package agent

import (
	"path/filepath"
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
