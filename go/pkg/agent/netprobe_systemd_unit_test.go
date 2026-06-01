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
		// Must equal the binary in ExecStart= of addons/netprobe/serviceradar-netprobe.service.
		wantStagedBinary = "/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe"
	)

	got := filepath.Join(resolveAddonArtifactRoot(""), netprobeAddonID, addonCurrentLink, netprobeBinaryName)
	if got != wantStagedBinary {
		t.Fatalf(
			"netprobe staged binary path = %q, want %q.\n"+
				"The verbatim-installed addons/netprobe/serviceradar-netprobe.service ExecStart must match this path; "+
				"update the unit and this test together.",
			got, wantStagedBinary,
		)
	}
}
