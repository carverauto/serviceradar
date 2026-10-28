//go:build !windows

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/agent/updaterflags"
)

func TestValidatedAgentUpdaterPathRejectsNonRootOwnedFile(t *testing.T) {
	tempDir := t.TempDir()
	updaterPath := filepath.Join(tempDir, "updater")
	if err := os.WriteFile(updaterPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	info, err := os.Stat(updaterPath)
	if err != nil {
		t.Fatalf("Stat() error = %v", err)
	}

	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("expected syscall.Stat_t for updater file")
	}
	if stat.Uid == 0 {
		if err := os.Chown(updaterPath, 1, int(stat.Gid)); err != nil {
			t.Fatalf("Chown() error = %v", err)
		}
	}

	_, err = validatePackageOwnedExecutable(updaterPath)
	if !errors.Is(err, errReleaseUpdaterOwnershipInvalid) {
		t.Fatalf("expected errReleaseUpdaterOwnershipInvalid, got %v", err)
	}
}

// TestAgentUpdaterCommandLinesMatchUpdaterFlags is the agent/updater CLI contract:
// every command line the agent builds must parse against the updater's real flag
// set into the intended options, and must pass the installed-updater flag probe
// against the help text that flag set prints.
func TestAgentUpdaterCommandLinesMatchUpdaterFlags(t *testing.T) {
	resources := agentaddon.Resources{CPUMaxPercent: 50, MemoryMaxBytes: 64 << 20, TasksMax: 32}
	install, err := systemdInstallUpdaterArgs(AddonSystemdInstallRequest{
		PrivilegedRoot:    "/opt/example/addons",
		AddonID:           "example-addon",
		Version:           "1.2.3",
		BinaryName:        "example-addon-bin",
		ArtifactPath:      "/var/lib/example/staged/example-addon.tar.gz",
		ArtifactSHA256:    strings.Repeat("a", 64),
		Signature:         "ZXhhbXBsZS1zaWduYXR1cmU=",
		Units:             []string{"example-addon.service", "example-addon.timer"},
		Enable:            "example-addon.timer",
		Resources:         resources,
		Capabilities:      []string{"cap_net_raw", "cap_bpf"},
		RunTimerNow:       true,
		StateSnapshotPath: "/var/lib/example/state/example-addon.snapshot",
	})
	if err != nil {
		t.Fatalf("systemdInstallUpdaterArgs() error = %v", err)
	}

	cases := []struct {
		name          string
		cmd           agentUpdaterArgs
		want          updaterflags.Options
		wantResources agentaddon.Resources
	}{
		{
			name: "systemd install",
			cmd:  install,
			want: updaterflags.Options{
				AddonID:                 "example-addon",
				AddonVersion:            "1.2.3",
				AddonBinary:             "example-addon-bin",
				AddonSHA256:             strings.Repeat("a", 64),
				AddonSignature:          "ZXhhbXBsZS1zaWduYXR1cmU=",
				AddonArtifact:           "/var/lib/example/staged/example-addon.tar.gz",
				AddonSystemdInstall:     "example-addon.service,example-addon.timer",
				AddonSystemdEnable:      "example-addon.timer",
				AddonSystemdRunTimerNow: true,
				AddonCapabilities:       "cap_bpf,cap_net_raw",
				PrivilegedRoot:          "/opt/example/addons",
				AddonStateSnapshot:      "/var/lib/example/state/example-addon.snapshot",
			},
			wantResources: resources,
		},
		{
			name: "systemd uninstall",
			cmd:  systemdUninstallUpdaterArgs([]string{"example-addon.service", "example-addon.timer"}),
			want: updaterflags.Options{AddonSystemdUninstall: "example-addon.service,example-addon.timer"},
		},
		{
			name: "release activation",
			cmd: releaseActivationUpdaterArgs("/var/lib/example/runtime", releaseActivationExecArgs{
				Version:     "1.2.3",
				CommandID:   "00000000-0000-4000-8000-000000000001",
				CommandType: "agent.update_release",
			}),
			want: updaterflags.Options{
				RuntimeRoot:      "/var/lib/example/runtime",
				Version:          "1.2.3",
				CommandID:        "00000000-0000-4000-8000-000000000001",
				CommandType:      "agent.update_release",
				RollbackDeadline: 3 * time.Minute,
			},
		},
	}

	helpPath := writeUpdaterHelpScript(t, realUpdaterUsage())
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fs := flag.NewFlagSet("serviceradar-agent-updater", flag.ContinueOnError)
			fs.SetOutput(io.Discard)
			got := updaterflags.Register(fs)
			if err := fs.Parse(tc.cmd.args); err != nil {
				t.Fatalf("updater rejected agent command line %q: %v", tc.cmd.args, err)
			}
			if fs.NArg() != 0 {
				t.Fatalf("updater left positional arguments %q", fs.Args())
			}

			var gotResources agentaddon.Resources
			if got.AddonSystemdResources != "" {
				if err := json.Unmarshal([]byte(got.AddonSystemdResources), &gotResources); err != nil {
					t.Fatalf("decode --%s: %v", updaterflags.AddonSystemdResources, err)
				}
				got.AddonSystemdResources = ""
			}
			if gotResources != tc.wantResources {
				t.Fatalf("resources = %+v, want %+v", gotResources, tc.wantResources)
			}

			want := tc.want
			if want.CommandType == "" {
				want.CommandType = updaterflags.DefaultCommandType
			}
			if want.RollbackDeadline == 0 {
				want.RollbackDeadline = updaterflags.DefaultRollbackDeadline
			}
			if *got != want {
				t.Fatalf("parsed options = %+v, want %+v", *got, want)
			}

			if err := validateAgentUpdaterSupportsFlags(helpPath, tc.cmd.flags...); err != nil {
				t.Fatalf("flag probe rejected the real updater help: %v", err)
			}
		})
	}
}

func TestValidateAgentUpdaterSupportsFlagsRejectsUndefinedFlag(t *testing.T) {
	cases := []struct {
		name     string
		usage    string
		required string
	}{
		{
			name: "updater predating add-on flags",
			usage: `
Usage of updater:
  -version string
  -command-id string
`,
			required: "addon-id",
		},
		{
			name:     "prefix of a defined flag",
			usage:    realUpdaterUsage(),
			required: "addon-bin",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateAgentUpdaterSupportsFlags(writeUpdaterHelpScript(t, tc.usage), tc.required)
			if !errors.Is(err, errReleaseUpdaterFlagUnsupported) {
				t.Fatalf("expected errReleaseUpdaterFlagUnsupported for --%s, got %v", tc.required, err)
			}
		})
	}
}

// realUpdaterUsage renders the help text the agent-updater prints for --help.
func realUpdaterUsage() string {
	var usage strings.Builder
	fs := flag.NewFlagSet("serviceradar-agent-updater", flag.ContinueOnError)
	updaterflags.Register(fs)
	fs.SetOutput(&usage)
	fmt.Fprintf(&usage, "Usage of %s:\n", fs.Name())
	fs.PrintDefaults()

	return usage.String()
}

func TestRunAgentUpdaterCommandIncludesOutput(t *testing.T) {
	updaterPath := writeExecutableScript(t, `
echo "unable to set CAP_SETFCAP effective capability: Operation not permitted" >&2
exit 1
`)

	err := runAgentUpdaterCommand(context.Background(), updaterPath, "--addon-id", "netprobe")
	if err == nil {
		t.Fatal("runAgentUpdaterCommand() error = nil, want failure")
	}
	if !strings.Contains(err.Error(), "unable to set CAP_SETFCAP effective capability") {
		t.Fatalf("runAgentUpdaterCommand() error = %q, want helper stderr", err)
	}
}

func writeUpdaterHelpScript(t *testing.T, usage string) string {
	t.Helper()

	return writeExecutableScript(t, "cat <<'EOF'\n"+strings.TrimSpace(usage)+"\nEOF\n")
}

func writeExecutableScript(t *testing.T, body string) string {
	t.Helper()

	updaterPath := filepath.Join(t.TempDir(), "updater")
	if err := os.WriteFile(updaterPath, []byte("#!/bin/sh\n"+strings.TrimSpace(body)+"\n"), 0o755); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	return updaterPath
}
