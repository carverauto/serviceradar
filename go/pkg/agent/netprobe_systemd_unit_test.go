package agent

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
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
		wantStagedBinary = "/usr/lib/serviceradar/addons/netprobe/current/serviceradar-netprobe"
		wantStagedEbpf   = "/usr/lib/serviceradar/addons/netprobe/current/netprobe_ebpf.o"
	)

	currentDir := filepath.Join(defaultPrivilegedAddonRoot, netprobeAddonID, addonCurrentLink)

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
	bundled, err := os.ReadFile(filepath.Join("..", "..", "..", "addons", "netprobe", "serviceradar-netprobe.service"))
	if err != nil {
		t.Fatalf("read netprobe unit: %v", err)
	}
	root := t.TempDir()
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	host := fixtureSystemHost(unitDir)
	host.systemctlPath = installMockSystemctl(t, t.TempDir())

	artPath, sha, sig, signingKey := createTestSignedAddonTarball(t, "serviceradar-netprobe", map[string][]byte{
		"serviceradar-netprobe.service": bundled,
	})
	if err := host.installUnits(context.Background(), AddonSystemdInstallRequest{
		RuntimeRoot:      root,
		PrivilegedRoot:   filepath.Join(root, "privileged"),
		AddonID:          "netprobe",
		Version:          "1.0.0",
		BinaryName:       "serviceradar-netprobe",
		ArtifactPath:     artPath,
		ArtifactSHA256:   sha,
		Signature:        sig,
		SigningPublicKey: signingKey,
		Units:            []string{"serviceradar-netprobe.service"},
		Enable:           "serviceradar-netprobe.service",
	}); err != nil {
		t.Fatalf("install netprobe unit: %v", err)
	}
	installed, err := os.ReadFile(filepath.Join(unitDir, "serviceradar-netprobe.service"))
	if err != nil {
		t.Fatalf("installed unit missing: %v", err)
	}
	directives := systemdDirectiveValues(installed)

	if got := directives["Group"]; len(got) != 1 || got[0] != "serviceradar" {
		t.Fatalf("Group = %v, want serviceradar", got)
	}
	if got := directives["Slice"]; len(got) != 1 || got[0] != "serviceradar.slice" {
		t.Fatalf("Slice = %v, want serviceradar.slice", got)
	}
	if got := directives["AmbientCapabilities"]; len(got) != 1 || got[0] != "CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON" {
		t.Fatalf("AmbientCapabilities = %v", got)
	}
	if got := directives["CapabilityBoundingSet"]; len(got) != 1 || got[0] != "CAP_NET_RAW CAP_NET_ADMIN CAP_BPF CAP_PERFMON CAP_SETUID CAP_SETGID CAP_SYS_PTRACE" {
		t.Fatalf("CapabilityBoundingSet = %v", got)
	}
	if got := directives["ReadWritePaths"]; len(got) != 1 {
		t.Fatalf("ReadWritePaths = %v", got)
	} else {
		wantPaths := []string{"/run/serviceradar", "/run/serviceradar/netprobe", "/var/lib/serviceradar", "/var/lib/serviceradar/netprobe", "/sys/fs/bpf"}
		for _, path := range wantPaths {
			if !strings.Contains(" "+got[0]+" ", " "+path+" ") {
				t.Fatalf("ReadWritePaths missing %s: %s", path, got[0])
			}
		}
	}
	if _, ok := directives["User"]; ok {
		t.Fatal("installed unit starts as User=; netprobe must load eBPF as root and then --drop-user")
	}
	if _, ok := directives["RuntimeDirectory"]; ok {
		t.Fatal("installed unit sets RuntimeDirectory")
	}
	if _, ok := directives["StateDirectory"]; ok {
		t.Fatal("installed unit sets StateDirectory")
	}

	execStart, ok := systemdCommandPath(directives["ExecStart"][0])
	if !ok || execStart != "/usr/lib/serviceradar/addons/netprobe/current/serviceradar-netprobe" {
		t.Fatalf("ExecStart command = %q", execStart)
	}
	if !strings.Contains(directives["ExecStart"][0], "--drop-user serviceradar") {
		t.Fatalf("ExecStart missing --drop-user serviceradar: %s", directives["ExecStart"][0])
	}

	joinedPre := strings.Join(directives["ExecStartPre"], "\n")
	for _, pre := range directives["ExecStartPre"] {
		command, ok := systemdCommandPath(pre)
		if !ok || (command != "/usr/bin/install" && command != "/usr/bin/rm") {
			t.Fatalf("ExecStartPre command = %q, want /usr/bin/install or /usr/bin/rm", command)
		}
	}
	for _, path := range []string{
		"/run/serviceradar/netprobe",
		"/var/lib/serviceradar/netprobe",
		"/sys/fs/bpf/flow_events",
		"/sys/fs/bpf/socket_to_pid",
		"/sys/fs/bpf/serviceradar/netprobe/flow_events",
		"/sys/fs/bpf/serviceradar/netprobe/socket_to_pid",
	} {
		if !strings.Contains(joinedPre, path) {
			t.Fatalf("installed ExecStartPre missing %s", path)
		}
	}
}

func systemdDirectiveValues(unit []byte) map[string][]string {
	out := map[string][]string{}
	section := ""
	for _, raw := range strings.Split(joinSystemdContinuations(string(unit)), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") {
			section = line
			continue
		}
		if section != "[Service]" || line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if value == "" {
			delete(out, key)
			continue
		}
		switch key {
		case "User", "Group", "Slice", "Delegate", "DelegateSubgroup", "StateDirectoryMode", "RuntimeDirectoryMode", "Restart":
			out[key] = []string{value}
		default:
			out[key] = append(out[key], value)
		}
	}
	return out
}

func TestAgentSystemdUnitDoesNotOwnSharedRuntimeDirectory(t *testing.T) {
	unit, err := os.ReadFile(filepath.Join("..", "..", "..", "build", "packaging", "agent", "systemd", "serviceradar-agent.service"))
	if err != nil {
		t.Fatal(err)
	}
	assertAgentRuntimeDirectives(t, unit)
	directives := systemdDirectiveValues(unit)
	for key, want := range map[string]string{"Slice": "serviceradar.slice", "Delegate": "yes"} {
		if !slices.Equal(directives[key], []string{want}) {
			t.Fatalf("%s = %v, want %s", key, directives[key], want)
		}
	}
	if len(directives["DelegateSubgroup"]) != 0 {
		t.Fatal("DelegateSubgroup requires newer systemd")
	}
	caps := strings.Fields(strings.Join(directives["CapabilityBoundingSet"], " "))
	for _, cap := range []string{"CAP_NET_RAW", "CAP_SETFCAP", "CAP_DAC_OVERRIDE", "CAP_FOWNER", "CAP_CHOWN", "CAP_MAC_ADMIN"} {
		if !slices.Contains(caps, cap) {
			t.Fatalf("missing bounding capability %s", cap)
		}
	}
}

func assertAgentRuntimeDirectives(t *testing.T, unit []byte) {
	t.Helper()
	directives := systemdDirectiveValues(unit)
	if slices.Contains(strings.Fields(strings.Join(directives["RuntimeDirectory"], " ")), "serviceradar") {
		t.Fatal("agent must not own the shared runtime directory lifecycle")
	}
	if values := directives["RuntimeDirectoryMode"]; len(values) > 0 {
		mode, err := strconv.ParseUint(values[0], 8, 32)
		if err != nil || mode == 0700 {
			t.Fatalf("shared runtime mode = %v", values)
		}
	}
	setup := false
	for _, command := range directives["ExecStartPre"] {
		if slices.Equal(strings.Fields(command), []string{"+/usr/bin/install", "-d", "-o", "serviceradar", "-g", "serviceradar", "-m", "0750", "/run/serviceradar"}) {
			setup = true
		}
	}
	if !setup {
		t.Fatal("missing explicit shared runtime setup")
	}
	states := strings.Fields(strings.Join(directives["StateDirectory"], " "))
	for _, dir := range []string{"serviceradar/agent", "serviceradar/agent/tmp", "serviceradar/agent/versions", "serviceradar/agent/versions/seed-installed"} {
		if !slices.Contains(states, dir) {
			t.Fatalf("missing state directory %s", dir)
		}
	}
	values := directives["StateDirectoryMode"]
	if len(values) != 1 {
		t.Fatalf("StateDirectoryMode = %v", values)
	}
	mode, err := strconv.ParseUint(values[0], 8, 32)
	if err != nil || mode != 0755 {
		t.Fatalf("StateDirectoryMode = %v", values)
	}
	exits := strings.Fields(strings.Join(directives["RestartPreventExitStatus"], " "))
	for _, status := range []string{"77", "78"} {
		if !slices.Contains(exits, status) {
			t.Fatalf("exit %s would restart", status)
		}
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
