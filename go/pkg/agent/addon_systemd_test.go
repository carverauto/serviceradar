/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/proto"
)

func TestValidateAddonUnitName(t *testing.T) {
	ok := []string{"serviceradar-netprobe.service", "serviceradar-bumblebee-scan.timer"}
	for _, name := range ok {
		if err := validateAddonUnitName(name); err != nil {
			t.Fatalf("validateAddonUnitName(%q) = %v, want nil", name, err)
		}
	}

	bad := []string{
		"../escape.service",     // traversal
		"sub/dir.service",       // separator
		"serviceradar-netprobe", // no unit suffix
		"serviceradar.conf",     // wrong suffix
		"",                      // empty
	}
	for _, name := range bad {
		if err := validateAddonUnitName(name); !errors.Is(err, ErrAddonUnitNameUnsafe) {
			t.Fatalf("validateAddonUnitName(%q) = %v, want ErrAddonUnitNameUnsafe", name, err)
		}
	}
}

// stageTestAddonUnit writes a staged unit file under <addonsRoot>/np/versions/1.0.0 and
// points the add-on's `current` symlink at it (mirroring a staged bundle's layout).
func stageTestAddonUnit(t *testing.T, addonsRoot, unitName, content string) {
	t.Helper()
	versionDir := filepath.Join(addonsRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		t.Fatalf("mkdir version dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(versionDir, unitName), []byte(content), 0o644); err != nil {
		t.Fatalf("write unit: %v", err)
	}
	current := filepath.Join(addonsRoot, "np", addonCurrentLink)
	_ = os.Remove(current)
	if err := os.Symlink(filepath.Join(addonVersionsDir, "1.0.0"), current); err != nil {
		t.Fatalf("symlink current: %v", err)
	}
}

func TestResolveStagedAddonUnit(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.service", "[Service]\nExecStart=/bin/true\n")

	got, err := resolveStagedAddonUnit(tmp, "np", "serviceradar-np.service")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if filepath.Base(got) != "serviceradar-np.service" {
		t.Fatalf("resolved base = %q", filepath.Base(got))
	}
	if data, err := os.ReadFile(got); err != nil || len(data) == 0 {
		t.Fatalf("resolved unit unreadable: %v", err)
	}

	// Unsafe names and ids are rejected.
	if _, err := resolveStagedAddonUnit(tmp, "np", "../evil.service"); !errors.Is(err, ErrAddonUnitNameUnsafe) {
		t.Fatalf("want ErrAddonUnitNameUnsafe, got %v", err)
	}
	if _, err := resolveStagedAddonUnit(tmp, "../etc", "serviceradar-np.service"); !errors.Is(err, ErrAddonUnsafePath) {
		t.Fatalf("want ErrAddonUnsafePath, got %v", err)
	}
}

func TestResolveStagedAddonUnitEscapeGuard(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	addonDir := filepath.Join(addonsRoot, "np")
	if err := os.MkdirAll(addonDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	outside := filepath.Join(tmp, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatalf("mkdir outside: %v", err)
	}
	if err := os.WriteFile(filepath.Join(outside, "serviceradar-np.service"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write outside unit: %v", err)
	}
	if err := os.Symlink(outside, filepath.Join(addonDir, addonCurrentLink)); err != nil {
		t.Fatalf("symlink current->outside: %v", err)
	}

	if _, err := resolveStagedAddonUnit(tmp, "np", "serviceradar-np.service"); !errors.Is(err, ErrAddonUnitEscape) {
		t.Fatalf("want ErrAddonUnitEscape, got %v", err)
	}
}

func TestInstalledBundledUnitsExecuteFromPrivilegedRoot(t *testing.T) {
	units := []struct {
		name       string
		addonID    string
		relPath    string
		wantBinary string
	}{
		{
			name:       "netprobe",
			addonID:    "netprobe",
			relPath:    filepath.Join("..", "..", "..", "addons", "netprobe", "serviceradar-netprobe.service"),
			wantBinary: "/usr/lib/serviceradar/addons/netprobe/current/serviceradar-netprobe",
		},
		{
			name:       "bumblebee",
			addonID:    "bumblebee",
			relPath:    filepath.Join("..", "..", "..", "addons", "bumblebee-scan", "serviceradar-bumblebee-scan.service"),
			wantBinary: "/usr/lib/serviceradar/addons/bumblebee/current/serviceradar-bumblebee-scan",
		},
		{
			name:       "scalibr",
			addonID:    "scalibr-endpoint-inventory",
			relPath:    filepath.Join("..", "..", "..", "addons", "scalibr-endpoint-inventory", "serviceradar-scalibr-endpoint-inventory.service"),
			wantBinary: "/usr/lib/serviceradar/addons/scalibr-endpoint-inventory/current/serviceradar-scalibr-endpoint-inventory",
		},
		{
			name:       "workload-identity",
			addonID:    "workload-identity",
			relPath:    filepath.Join("..", "..", "..", "addons", "workload-identity", "serviceradar-workload-identity.service"),
			wantBinary: "/usr/lib/serviceradar/addons/workload-identity/current/serviceradar-workload-identity",
		},
	}

	for _, tc := range units {
		t.Run(tc.name, func(t *testing.T) {
			bundled, err := os.ReadFile(tc.relPath)
			if err != nil {
				t.Fatalf("read unit file %s: %v", tc.relPath, err)
			}
			unitName := filepath.Base(tc.relPath)
			binary := filepath.Base(tc.wantBinary)
			root := t.TempDir()
			unitDir := filepath.Join(root, "systemd")
			if err := os.MkdirAll(unitDir, 0o755); err != nil {
				t.Fatal(err)
			}
			origUnitDir := systemdUnitDir
			systemdUnitDir = unitDir
			t.Cleanup(func() { systemdUnitDir = origUnitDir })
			installMockSystemctl(t, t.TempDir())

			artPath, sha, sig := createTestSignedAddonTarball(t, binary, map[string][]byte{
				unitName: bundled,
			})
			err = InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
				RuntimeRoot:    root,
				PrivilegedRoot: filepath.Join(root, "privileged"),
				AddonID:        tc.addonID,
				Version:        "1.0.0",
				BinaryName:     binary,
				ArtifactPath:   artPath,
				ArtifactSHA256: sha,
				Signature:      sig,
				Units:          []string{unitName},
				Enable:         unitName,
			})
			if err != nil {
				t.Fatalf("install bundled unit: %v", err)
			}

			installed, err := os.ReadFile(filepath.Join(unitDir, unitName))
			if err != nil {
				t.Fatalf("installed unit missing: %v", err)
			}
			paths := systemdUnitCommandPaths(installed)
			if len(paths) == 0 {
				t.Fatal("installed unit has no executable command")
			}
			for _, path := range paths {
				for _, writable := range writableAddonRoots("") {
					if pathIsWithin(filepath.Clean(path), writable) {
						t.Fatalf("installed command %s executes from the agent-writable tree", path)
					}
				}
			}
			var execStart string
			for _, raw := range strings.Split(joinSystemdContinuations(string(installed)), "\n") {
				line := strings.TrimSpace(raw)
				key, value, ok := strings.Cut(line, "=")
				if ok && strings.TrimSpace(key) == "ExecStart" {
					execStart, _ = systemdCommandPath(value)
					break
				}
			}
			if execStart != tc.wantBinary {
				t.Fatalf("installed ExecStart = %q, want %q", execStart, tc.wantBinary)
			}
		})
	}
}

func TestInstallAddonSystemdUnitsRejectsAgentWritableExecPath(t *testing.T) {
	root := t.TempDir()
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	origUnitDir := systemdUnitDir
	systemdUnitDir = unitDir
	t.Cleanup(func() { systemdUnitDir = origUnitDir })
	installMockSystemctl(t, t.TempDir())

	writableExec := filepath.Join(resolveAddonArtifactRoot(root), "np", addonCurrentLink, "serviceradar-np")
	publishedExec := "/var/lib/serviceradar/agent/addons/np/current/serviceradar-np"
	for _, execPath := range []string{writableExec, publishedExec} {
		t.Run(execPath, func(t *testing.T) {
			unit := "[Service]\nExecStartPre=+/usr/bin/install -d /run/serviceradar\nExecStartPre=" + execPath + "\nExecStart=" + execPath + "\n"
			artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
				"serviceradar-np.service": []byte(unit),
			})
			err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
				RuntimeRoot:    root,
				PrivilegedRoot: filepath.Join(root, "privileged"),
				AddonID:        "np",
				Version:        "1.0.0",
				BinaryName:     "serviceradar-np",
				ArtifactPath:   artPath,
				ArtifactSHA256: sha,
				Signature:      sig,
				Units:          []string{"serviceradar-np.service"},
				Enable:         "serviceradar-np.service",
			})
			if !errors.Is(err, ErrAddonUnitExecPathUnsafe) {
				t.Fatalf("want ErrAddonUnitExecPathUnsafe, got %v", err)
			}
			if _, statErr := os.Stat(filepath.Join(unitDir, "serviceradar-np.service")); !os.IsNotExist(statErr) {
				t.Fatalf("rejected unit was installed: %v", statErr)
			}
		})
	}

	preOnly := "[Service]\nExecStartPre=" + publishedExec + "\nExecStart=/bin/true\n"
	artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": []byte(preOnly),
	})
	err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: filepath.Join(root, "privileged"),
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   artPath,
		ArtifactSHA256: sha,
		Signature:      sig,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
	})
	if !errors.Is(err, ErrAddonUnitExecPathUnsafe) {
		t.Fatalf("ExecStartPre writable path: want ErrAddonUnitExecPathUnsafe, got %v", err)
	}
}

func TestInstallAddonSystemdUnitsRequiresDigestBeforeExtract(t *testing.T) {
	root := t.TempDir()
	priv := filepath.Join(root, "privileged")
	artPath, _, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": []byte("[Service]\nExecStart=/bin/true\n"),
	})
	err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: priv,
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   artPath,
		Signature:      sig,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
	})
	if !errors.Is(err, ErrAddonArtifactIncomplete) {
		t.Fatalf("want ErrAddonArtifactIncomplete, got %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(priv, "np")); !os.IsNotExist(statErr) {
		t.Fatalf("artifact extracted without a digest: %v", statErr)
	}
}

func TestInstallAddonSystemdUnitsRestoresPreviousUnitWhenActivationFails(t *testing.T) {
	root := t.TempDir()
	priv := filepath.Join(root, "privileged")
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	origUnitDir := systemdUnitDir
	systemdUnitDir = unitDir
	t.Cleanup(func() { systemdUnitDir = origUnitDir })

	logPath := filepath.Join(root, "systemctl.log")
	failOnce := filepath.Join(root, "fail-once")
	mockDir := t.TempDir()
	script := "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"$SYSTEMCTL_LOG\"\ncmd=\"${1:-}\"\nif [ \"$cmd\" = \"enable\" ] && [ ! -f \"$SYSTEMCTL_FAIL_ONCE\" ]; then\n  touch \"$SYSTEMCTL_FAIL_ONCE\"\n  exit 1\nfi\nexit 0\n"
	if err := os.WriteFile(filepath.Join(mockDir, "systemctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", mockDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SYSTEMCTL_LOG", logPath)
	t.Setenv("SYSTEMCTL_FAIL_ONCE", failOnce)

	previous := []byte("[Service]\nExecStart=/usr/lib/serviceradar/addons/np/current/serviceradar-np\n")
	if err := os.WriteFile(filepath.Join(unitDir, "serviceradar-np.service"), previous, 0o644); err != nil {
		t.Fatal(err)
	}
	replacement := []byte("[Service]\nExecStart=/usr/lib/serviceradar/addons/np/current/serviceradar-np-v2\n")
	artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": replacement,
	})
	err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: priv,
		AddonID:        "np",
		Version:        "2.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   artPath,
		ArtifactSHA256: sha,
		Signature:      sig,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
	})
	if err == nil {
		t.Fatal("expected activation to fail")
	}
	got, readErr := os.ReadFile(filepath.Join(unitDir, "serviceradar-np.service"))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(got) != string(previous) {
		t.Fatalf("previous unit was not restored: %q", got)
	}
	if _, statErr := os.Lstat(filepath.Join(priv, "np", addonCurrentLink)); !os.IsNotExist(statErr) {
		t.Fatalf("failed first privileged activation left current in place: %v", statErr)
	}
	log, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	disabled := false
	reenabled := false
	for _, line := range strings.Split(strings.TrimSpace(string(log)), "\n") {
		if strings.HasPrefix(line, "disable --now") {
			disabled = true
		}
		if disabled && strings.HasPrefix(line, "enable --now") {
			reenabled = true
		}
	}
	if !reenabled {
		t.Fatalf("prior service was not re-enabled after activation failure: %s", log)
	}
}

func TestInstallAddonSystemdUnitsSetcapTargetsPrivilegedBinary(t *testing.T) {
	root := t.TempDir()
	priv := filepath.Join(root, "privileged")
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	origUnitDir := systemdUnitDir
	systemdUnitDir = unitDir
	t.Cleanup(func() { systemdUnitDir = origUnitDir })
	installMockSystemctl(t, t.TempDir())

	setcapLog := filepath.Join(root, "setcap.log")
	setcapDir := t.TempDir()
	setcapScript := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$SETCAP_LOG\"\nexit 0\n"
	if err := os.WriteFile(filepath.Join(setcapDir, "setcap"), []byte(setcapScript), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", setcapDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SETCAP_LOG", setcapLog)

	writableBin := filepath.Join(resolveAddonArtifactRoot(root), "np", addonCurrentLink, "serviceradar-np")
	if err := os.MkdirAll(filepath.Dir(writableBin), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(writableBin, []byte("replaced"), 0o755); err != nil {
		t.Fatal(err)
	}

	artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": []byte("[Service]\nExecStart=/bin/true\n"),
	})
	err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: priv,
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   artPath,
		ArtifactSHA256: sha,
		Signature:      sig,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
		Capabilities:   []string{"CAP_NET_RAW"},
	})
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	log, readErr := os.ReadFile(setcapLog)
	if readErr != nil {
		t.Fatalf("setcap was not invoked: %v", readErr)
	}
	if !strings.Contains(string(log), priv) {
		t.Fatalf("setcap did not target the privileged tree: %s", log)
	}
	if strings.Contains(string(log), writableBin) {
		t.Fatalf("setcap targeted the agent-writable binary: %s", log)
	}
}

func createTestSignedAddonTarball(t *testing.T, binName string, files map[string][]byte) (string, string, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	setReleaseVerificationKey(t, hex.EncodeToString(pub))

	allFiles := make(map[string][]byte)
	for k, v := range files {
		allFiles[k] = v
	}
	if _, ok := allFiles[binName]; !ok {
		allFiles[binName] = []byte("#!/bin/sh\nexit 0\n")
	}

	data := makeAddonTarGz(t, allFiles)
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	sig := hex.EncodeToString(ed25519.Sign(priv, data))

	dir := t.TempDir()
	artifactPath := filepath.Join(dir, "artifact.tar.gz")
	if err := os.WriteFile(artifactPath, data, 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}

	return artifactPath, sha, sig
}

func installMockSystemctl(t *testing.T, dir string) {
	t.Helper()
	script := `#!/bin/sh
set -eu
cmd="${1:-}"
case "$cmd" in
  daemon-reload|enable|disable|start|stop|restart|reset-failed)
    exit 0
    ;;
  show)
    printf 'ActiveState=active\nSubState=running\nResult=success\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func TestInstallAddonSystemdUnitsFailureVectors(t *testing.T) {
	artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": []byte("[Service]\nExecStart=/bin/true\n"),
	})

	baseReq := AddonSystemdInstallRequest{
		RuntimeRoot:    t.TempDir(),
		PrivilegedRoot: t.TempDir(),
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   artPath,
		ArtifactSHA256: sha,
		Signature:      sig,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
	}

	t.Run("missing signature rejected", func(t *testing.T) {
		req := baseReq
		req.Signature = ""
		if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonSignatureRequired) {
			t.Fatalf("want ErrAddonSignatureRequired, got %v", err)
		}
	})

	t.Run("invalid signature rejected", func(t *testing.T) {
		req := baseReq
		_, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
		req.Signature = hex.EncodeToString(ed25519.Sign(otherPriv, []byte("tampered")))
		if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonSignatureInvalid) {
			t.Fatalf("want ErrAddonSignatureInvalid, got %v", err)
		}
	})

	t.Run("sha256 digest mismatch rejected", func(t *testing.T) {
		req := baseReq
		req.ArtifactSHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
		if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonArtifactHashMismatch) {
			t.Fatalf("want ErrAddonArtifactHashMismatch, got %v", err)
		}
	})

	t.Run("missing artifact file rejected", func(t *testing.T) {
		req := baseReq
		req.ArtifactPath = filepath.Join(t.TempDir(), "nonexistent.tar.gz")
		if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonArtifactMissing) {
			t.Fatalf("want ErrAddonArtifactMissing, got %v", err)
		}
	})

	t.Run("path traversal rejected", func(t *testing.T) {
		badIDs := []string{"../escape", "sub/dir", "", ".."}
		for _, bad := range badIDs {
			req := baseReq
			req.AddonID = bad
			if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonUnsafePath) {
				t.Fatalf("AddonID=%q: want ErrAddonUnsafePath, got %v", bad, err)
			}

			req = baseReq
			req.Version = bad
			if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonUnsafePath) {
				t.Fatalf("Version=%q: want ErrAddonUnsafePath, got %v", bad, err)
			}

			req = baseReq
			req.BinaryName = bad
			if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonUnsafePath) {
				t.Fatalf("BinaryName=%q: want ErrAddonUnsafePath, got %v", bad, err)
			}
		}

		badUnits := []string{"../escape.service", "sub/dir.service", "evil.conf"}
		for _, bad := range badUnits {
			req := baseReq
			req.Units = []string{bad}
			req.Enable = bad
			if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonUnitNameUnsafe) {
				t.Fatalf("Units=%q: want ErrAddonUnitNameUnsafe, got %v", bad, err)
			}
		}
	})
}

func TestInstallAddonSystemdUnitsStagedFileReplacementResistance(t *testing.T) {
	root := t.TempDir()
	privRoot := filepath.Join(root, "privileged-addons")
	stagingRoot := resolveAddonArtifactRoot(root)
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	origUnitDir := systemdUnitDir
	systemdUnitDir = unitDir
	t.Cleanup(func() { systemdUnitDir = origUnitDir })

	mockDir := t.TempDir()
	installMockSystemctl(t, mockDir)

	authenticContent := "[Service]\nExecStart=/usr/lib/serviceradar/addons/np/current/serviceradar-np\n"
	artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": []byte(authenticContent),
	})

	stagingVerDir := filepath.Join(stagingRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.MkdirAll(stagingVerDir, 0o755); err != nil {
		t.Fatal(err)
	}
	stagedArtPath := filepath.Join(stagingVerDir, "artifact.tar.gz")
	artBytes, err := os.ReadFile(artPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stagedArtPath, artBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	tamperedUnit := filepath.Join(stagingVerDir, "serviceradar-np.service")
	if err := os.WriteFile(tamperedUnit, []byte("[Service]\nExecStart=/tmp/malicious\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	req := AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: privRoot,
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   stagedArtPath,
		ArtifactSHA256: sha,
		Signature:      sig,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
	}

	if err := InstallAddonSystemdUnits(context.Background(), req); err != nil {
		t.Fatalf("InstallAddonSystemdUnits failed: %v", err)
	}

	installedUnit, err := os.ReadFile(filepath.Join(unitDir, "serviceradar-np.service"))
	if err != nil {
		t.Fatalf("read installed unit: %v", err)
	}
	if string(installedUnit) != authenticContent {
		t.Fatalf("installed unit compromised by staged file replacement: got %q, want %q", string(installedUnit), authenticContent)
	}

	if err := os.WriteFile(stagedArtPath, []byte("tampered-archive-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonArtifactHashMismatch) {
		t.Fatalf("want ErrAddonArtifactHashMismatch on tampered archive, got %v", err)
	}
}

func TestInstallAddonSystemdUnitsLifecycle(t *testing.T) {
	root := t.TempDir()
	privRoot := filepath.Join(root, "privileged-addons")
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	origUnitDir := systemdUnitDir
	systemdUnitDir = unitDir
	t.Cleanup(func() { systemdUnitDir = origUnitDir })

	mockDir := t.TempDir()
	installMockSystemctl(t, mockDir)

	// Step 1: Initial activation of v1.0.0
	art1, sha1, sig1 := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service": []byte("[Service]\nExecStart=/bin/true\n"),
		"np.json":                 []byte(`{"mode":"prod"}`),
	})

	req1 := AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: privRoot,
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   art1,
		ArtifactSHA256: sha1,
		Signature:      sig1,
		Units:          []string{"serviceradar-np.service"},
		Enable:         "serviceradar-np.service",
	}

	if err := InstallAddonSystemdUnits(context.Background(), req1); err != nil {
		t.Fatalf("Install v1.0.0 failed: %v", err)
	}

	v1Dir := filepath.Join(privRoot, "np", addonVersionsDir, "1.0.0")
	if info, err := os.Stat(v1Dir); err != nil || !info.IsDir() {
		t.Fatalf("v1.0.0 directory not created: %v", err)
	}
	curTarget, ok := readAddonCurrentTarget(filepath.Join(privRoot, "np"))
	if !ok || curTarget != filepath.Join(addonVersionsDir, "1.0.0") {
		t.Fatalf("current target = %q, want versions/1.0.0", curTarget)
	}
	if _, err := os.Stat(filepath.Join(unitDir, "serviceradar-np.service")); err != nil {
		t.Fatalf("unit not installed in systemd dir: %v", err)
	}

	// Step 2: Re-configuration writes to state/ without modifying privRoot
	stageTestAddonFiles(t, resolveAddonArtifactRoot(root), "np", map[string]string{
		"np.json": `{"mode":"prod"}`,
	})
	cfgAssignment := &proto.AddonAssignmentConfig{
		AddonId:    "np",
		ConfigJson: []byte(`{"mode":"debug","extra":"val"}`),
	}
	if err := applyStagedAddonRuntimeConfig(root, cfgAssignment); err != nil {
		t.Fatalf("applyStagedAddonRuntimeConfig failed: %v", err)
	}
	stateConfigFile := filepath.Join(addonStateDir(root, "np"), "np.json")
	stateData, err := os.ReadFile(stateConfigFile)
	if err != nil {
		t.Fatalf("read state config file: %v", err)
	}
	if !strings.Contains(string(stateData), "debug") {
		t.Fatalf("state config not updated: %s", string(stateData))
	}
	privData, err := os.ReadFile(filepath.Join(v1Dir, "np.json"))
	if err != nil {
		t.Fatalf("read privileged config file: %v", err)
	}
	if strings.Contains(string(privData), "debug") {
		t.Fatalf("privileged root was modified by reconfiguration!")
	}

	// Step 3: Rollback on failed activation of v2.0.0
	art2, sha2, sig2 := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.service":     []byte("[Service]\nExecStart=/bin/true\n"),
		"serviceradar-np-new.service": []byte("[Service]\nExecStart=/bin/false\n"),
	})

	failScript := `#!/bin/sh
set -eu
cmd="${1:-}"
if [ "$cmd" = "enable" ]; then
  exit 1
fi
exit 0
`
	if err := os.WriteFile(filepath.Join(mockDir, "systemctl"), []byte(failScript), 0o755); err != nil {
		t.Fatal(err)
	}

	req2 := AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: privRoot,
		AddonID:        "np",
		Version:        "2.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   art2,
		ArtifactSHA256: sha2,
		Signature:      sig2,
		Units:          []string{"serviceradar-np.service", "serviceradar-np-new.service"},
		Enable:         "serviceradar-np.service",
	}

	if err := InstallAddonSystemdUnits(context.Background(), req2); err == nil {
		t.Fatal("expected Install v2.0.0 to fail when systemctl fails")
	}

	curTarget, ok = readAddonCurrentTarget(filepath.Join(privRoot, "np"))
	if !ok || curTarget != filepath.Join(addonVersionsDir, "1.0.0") {
		t.Fatalf("after failed install, current target = %q, want versions/1.0.0", curTarget)
	}

	if _, err := os.Stat(filepath.Join(unitDir, "serviceradar-np-new.service")); !os.IsNotExist(err) {
		t.Fatalf("newly created unit was not cleaned up on failure: %v", err)
	}
	if _, err := os.Stat(filepath.Join(unitDir, "serviceradar-np.service")); err != nil {
		t.Fatalf("pre-existing unit was deleted: %v", err)
	}
}

func TestStagedAddonExecutablesSelectsBinariesOnly(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.service", "[Service]\nExecStart=/bin/true\n")
	versionDir := filepath.Join(addonsRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.WriteFile(filepath.Join(versionDir, "serviceradar-np"), []byte("bin"), 0o755); err != nil {
		t.Fatalf("write binary: %v", err)
	}
	if err := os.WriteFile(filepath.Join(versionDir, "config.json"), []byte(`{}`), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(versionDir, "probe.o"), []byte("obj"), 0o755); err != nil {
		t.Fatalf("write object: %v", err)
	}

	got := stagedAddonExecutables(tmp, "np")
	if len(got) != 1 || filepath.Base(got[0]) != "serviceradar-np" {
		t.Fatalf("stagedAddonExecutables = %v, want [serviceradar-np]", got)
	}
}

func TestInstallAddonSystemdUnitsValidation(t *testing.T) {
	// No units -> ErrAddonSystemdNoUnits (before any systemctl/exec).
	if err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{AddonID: "np"}); !errors.Is(err, ErrAddonSystemdNoUnits) {
		t.Fatalf("want ErrAddonSystemdNoUnits, got %v", err)
	}

	// Enable unit not in the unit set -> ErrAddonSystemdEnableNotListed.
	req := AddonSystemdInstallRequest{
		AddonID: "np",
		Units:   []string{"a.service"},
		Enable:  "b.timer",
	}
	if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonSystemdEnableNotListed) {
		t.Fatalf("want ErrAddonSystemdEnableNotListed, got %v", err)
	}
}

func TestTimerCandidateActivationReevaluatesBackingServiceHealth(t *testing.T) {
	for _, tc := range []struct {
		name, timerContent, service string
	}{
		{"default service", "[Timer]\nOnUnitActiveSec=6h\n", "serviceradar-np.service"},
		{"explicit service", "[Timer]\nUnit=serviceradar-np-scan.service\n", "serviceradar-np-scan.service"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			state := filepath.Join(root, "service-state")
			run := filepath.Join(root, "candidate-run")
			if err := os.WriteFile(state, []byte("failed"), 0o600); err != nil {
				t.Fatal(err)
			}
			installTimerSystemctlFixture(t, root, state, run, tc.service)
			timerPath := filepath.Join(root, "serviceradar-np.timer")
			if err := os.WriteFile(timerPath, []byte(tc.timerContent), 0o600); err != nil {
				t.Fatal(err)
			}
			units := []string{"serviceradar-np.timer", tc.service}
			service, err := stagedTimerService(timerPath, units[0], units)
			if err != nil {
				t.Fatal(err)
			}
			health := func() systemdUnitStatus {
				return systemdAddonUnitStatusWithReader(units, readSystemdUnitStatusDefault)
			}
			if health().state != agentaddon.StateUnhealthy {
				t.Fatal("the previous scanner failure must be visible before candidate activation")
			}
			if err := activateAddonSystemdUnits(context.Background(), units[0], service); err != nil {
				t.Fatal(err)
			}
			if got := health(); got.state != agentaddon.StateRunning || got.lastError != "" {
				t.Fatalf("candidate inherited previous failure: %#v", got)
			}
			if got, err := os.ReadFile(run); err != nil || string(got) != tc.service {
				t.Fatalf("the staged candidate was not queued for execution: %q, %v", got, err)
			}

			// A failure of this candidate remains observable; a same-version
			// timer reconciliation cannot erase it or continually rerun the scan.
			if err := os.WriteFile(state, []byte("failed"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Remove(run); err != nil {
				t.Fatal(err)
			}
			if err := activateAddonSystemdUnits(context.Background(), units[0], ""); err != nil {
				t.Fatal(err)
			}
			if health().state != agentaddon.StateUnhealthy {
				t.Fatal("same-version reconciliation erased a genuine candidate failure")
			}
			if _, err := os.Stat(run); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("same-version reconciliation unexpectedly queued another run: %v", err)
			}
		})
	}
}

func TestTimerCandidateActivationRejectsUnbundledServiceBeforeInstallation(t *testing.T) {
	root := t.TempDir()
	privRoot := filepath.Join(root, "privileged-addons")
	unitDir := filepath.Join(root, "systemd")
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	origUnitDir := systemdUnitDir
	systemdUnitDir = unitDir
	t.Cleanup(func() { systemdUnitDir = origUnitDir })

	mockDir := t.TempDir()
	installMockSystemctl(t, mockDir)

	artPath, sha, sig := createTestSignedAddonTarball(t, "serviceradar-np", map[string][]byte{
		"serviceradar-np.timer": []byte("[Timer]\nUnit=unrelated-host.service\n"),
	})

	err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{
		RuntimeRoot:    root,
		PrivilegedRoot: privRoot,
		AddonID:        "np",
		Version:        "1.0.0",
		BinaryName:     "serviceradar-np",
		ArtifactPath:   artPath,
		ArtifactSHA256: sha,
		Signature:      sig,
		Units:          []string{"serviceradar-np.timer"},
		Enable:         "serviceradar-np.timer",
		RunTimerNow:    true,
	})
	if !errors.Is(err, ErrAddonSystemdEnableNotListed) {
		t.Fatalf("unbundled backing service was not rejected before host writes: %v", err)
	}

	if _, err := os.Lstat(filepath.Join(privRoot, "np", addonCurrentLink)); !os.IsNotExist(err) {
		t.Fatalf("expected current link to be removed after rejected install: %v", err)
	}
}

func TestTimerCandidateActivationPropagatesResetAndQueueFailures(t *testing.T) {
	for _, fail := range []string{"reset-failed", "queue"} {
		t.Run(fail, func(t *testing.T) {
			root := t.TempDir()
			state := filepath.Join(root, "service-state")
			run := filepath.Join(root, "candidate-run")
			installTimerSystemctlFixture(t, root, state, run, "serviceradar-np.service")
			t.Setenv("TIMER_FIXTURE_FAIL", fail)
			if err := activateAddonSystemdUnits(context.Background(), "serviceradar-np.timer",
				"serviceradar-np.service"); err == nil {
				t.Fatal("a failed fresh activation must not be reported as successful")
			}
			if _, err := os.Stat(run); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("failed activation unexpectedly executed the candidate: %v", err)
			}
		})
	}
}

func installTimerSystemctlFixture(t *testing.T, dir, state, run, service string) {
	t.Helper()
	// This executable supplies only the external systemctl protocol. Production
	// command execution and health parsing run unchanged, without host systemd.
	script := `#!/bin/sh
set -eu
command=$1
shift
case "$command" in
  reset-failed)
    [ "${TIMER_FIXTURE_FAIL:-}" != reset-failed ] || exit 1
    printf inactive > "$TIMER_FIXTURE_STATE"
    ;;
  enable) ;;
  daemon-reload) ;;
  restart)
    if [ "$1" = --no-block ]; then
      [ "${TIMER_FIXTURE_FAIL:-}" != queue ] || exit 1
      [ "$2" = "$TIMER_FIXTURE_SERVICE" ] || exit 2
      [ "$(cat "$TIMER_FIXTURE_STATE")" = inactive ] || exit 3
      printf active > "$TIMER_FIXTURE_STATE"
      printf '%s' "$2" > "$TIMER_FIXTURE_RUN"
    fi
    ;;
  show)
    for unit in "$@"; do :; done
    case "$unit" in
      *.timer) printf 'ActiveState=active\nSubState=waiting\nNextElapseUSecMonotonic=123456\n' ;;
      *.service)
        if [ "$(cat "$TIMER_FIXTURE_STATE")" = failed ]; then
          printf 'ActiveState=failed\nResult=exit-code\nExecMainStatus=1\n'
        else
          printf 'ActiveState=active\nMainPID=456\nResult=success\nExecMainStatus=0\n'
        fi
        ;;
    esac
    ;;
  *) exit 4 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TIMER_FIXTURE_STATE", state)
	t.Setenv("TIMER_FIXTURE_RUN", run)
	t.Setenv("TIMER_FIXTURE_SERVICE", service)
}

func TestUninstallAddonSystemdUnitsValidation(t *testing.T) {
	if err := UninstallAddonSystemdUnits(context.Background(), nil); !errors.Is(err, ErrAddonSystemdNoUnits) {
		t.Fatalf("want ErrAddonSystemdNoUnits, got %v", err)
	}
	if err := UninstallAddonSystemdUnits(context.Background(), []string{"../evil.service"}); !errors.Is(err, ErrAddonUnitNameUnsafe) {
		t.Fatalf("want ErrAddonUnitNameUnsafe, got %v", err)
	}
}

func TestDiscoverStagedAddonUnits(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.timer", "[Timer]\n")
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.service", "[Service]\nExecStart=/bin/true\n")
	// A non-unit file in the staged dir (e.g. the binary) must be ignored.
	versionDir := filepath.Join(addonsRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.WriteFile(filepath.Join(versionDir, "serviceradar-np-addon"), []byte("bin"), 0o755); err != nil {
		t.Fatalf("write binary: %v", err)
	}

	got, err := discoverStagedAddonUnits(tmp, "np")
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	want := []string{"serviceradar-np.service", "serviceradar-np.timer"} // sorted, units only
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("discover = %v, want %v", got, want)
	}

	if _, err := discoverStagedAddonUnits(tmp, "../etc"); !errors.Is(err, ErrAddonUnsafePath) {
		t.Fatalf("want ErrAddonUnsafePath for unsafe id, got %v", err)
	}
}

func TestPickPrimarySystemdUnit(t *testing.T) {
	units := []string{"x.service", "x.timer"}

	if got, err := pickPrimarySystemdUnit(units, addonSupervisionSystemdTimer); err != nil || got != "x.timer" {
		t.Fatalf("timer mode = %q,%v; want x.timer", got, err)
	}
	if got, err := pickPrimarySystemdUnit(units, addonSupervisionSystemdService); err != nil || got != "x.service" {
		t.Fatalf("service mode = %q,%v; want x.service", got, err)
	}

	// Two timers -> ambiguous.
	if _, err := pickPrimarySystemdUnit([]string{"a.timer", "b.timer"}, addonSupervisionSystemdTimer); !errors.Is(err, ErrAddonSystemdPrimaryAmbiguous) {
		t.Fatalf("want ErrAddonSystemdPrimaryAmbiguous, got %v", err)
	}
	// No service for service mode -> ambiguous (zero matches).
	if _, err := pickPrimarySystemdUnit([]string{"a.timer"}, addonSupervisionSystemdService); !errors.Is(err, ErrAddonSystemdPrimaryAmbiguous) {
		t.Fatalf("want ErrAddonSystemdPrimaryAmbiguous for no service, got %v", err)
	}
	// Unknown supervision model.
	if _, err := pickPrimarySystemdUnit(units, "agent_sidecar"); !errors.Is(err, ErrAddonSystemdSupervisionUnknown) {
		t.Fatalf("want ErrAddonSystemdSupervisionUnknown, got %v", err)
	}
}

func TestSystemdAddonsToRemove(t *testing.T) {
	installed := map[string][]string{
		"netprobe":  {"serviceradar-netprobe.service"},
		"bumblebee": {"serviceradar-bumblebee.service", "serviceradar-bumblebee.timer"},
		"gone":      {"gone.service"},
	}

	// netprobe + bumblebee still desired; "gone" is no longer assigned.
	toRemove := systemdAddonsToRemove(installed, map[string]bool{"netprobe": true, "bumblebee": true})
	if !reflect.DeepEqual(toRemove, map[string][]string{"gone": {"gone.service"}}) {
		t.Fatalf("toRemove = %v, want only 'gone'", toRemove)
	}

	// All desired -> nothing to remove.
	if got := systemdAddonsToRemove(installed, map[string]bool{"netprobe": true, "bumblebee": true, "gone": true}); got != nil {
		t.Fatalf("expected nil when all desired, got %v", got)
	}

	// None desired -> all removed.
	if got := systemdAddonsToRemove(installed, map[string]bool{}); len(got) != 3 {
		t.Fatalf("expected all 3 removed when none desired, got %v", got)
	}
}

func TestStringsNotIn(t *testing.T) {
	if got := stringsNotIn([]string{"a", "b", "c"}, []string{"b", "c"}); !reflect.DeepEqual(got, []string{"a"}) {
		t.Fatalf("stringsNotIn = %v, want [a]", got)
	}
	if got := stringsNotIn([]string{"x"}, []string{"x", "y"}); got != nil {
		t.Fatalf("expected nil when all present, got %v", got)
	}
	if got := stringsNotIn(nil, []string{"a"}); got != nil {
		t.Fatalf("expected nil for empty input, got %v", got)
	}
}

// stageTestAddonFiles stages arbitrary files under <addonsRoot>/<id>/versions/1.0.0 and
// points the add-on's current symlink at them.
func stageTestAddonFiles(t *testing.T, addonsRoot, id string, files map[string]string) {
	t.Helper()
	vdir := filepath.Join(addonsRoot, id, addonVersionsDir, "1.0.0")
	if err := os.MkdirAll(vdir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(vdir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	current := filepath.Join(addonsRoot, id, addonCurrentLink)
	_ = os.Remove(current)
	if err := os.Symlink(filepath.Join(addonVersionsDir, "1.0.0"), current); err != nil {
		t.Fatalf("symlink current: %v", err)
	}
}

func TestDiscoverInstalledSystemdAddons(t *testing.T) {
	root := filepath.Join(t.TempDir(), addonsDirName)
	stageTestAddonFiles(t, root, "np", map[string]string{
		"serviceradar-np.service": "[Service]\n",
		"serviceradar-np.timer":   "[Timer]\n",
	})
	// A sidecar-style add-on with no unit files must be excluded.
	stageTestAddonFiles(t, root, "sidecaronly", map[string]string{
		"serviceradar-sidecaronly-addon": "bin",
	})

	got := discoverInstalledSystemdAddons(root)
	want := map[string][]string{"np": {"serviceradar-np.service", "serviceradar-np.timer"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("discoverInstalledSystemdAddons = %v, want %v", got, want)
	}

	if got := discoverInstalledSystemdAddons(filepath.Join(t.TempDir(), "absent")); got != nil {
		t.Fatalf("expected nil for missing root, got %v", got)
	}
}

func TestRenderSystemdResourceDropIn(t *testing.T) {
	got := renderSystemdResourceDropIn(agentaddon.Resources{
		CPUMaxPercent:   50,
		MemoryMaxBytes:  268435456,
		MemoryHighBytes: 201326592,
		TasksMax:        32,
		Slice:           "serviceradar-addons.slice",
	})

	for _, want := range []string{
		"[Service]",
		"CPUQuota=50%",
		"MemoryHigh=201326592",
		"MemoryMax=268435456",
		"TasksMax=32",
		"Slice=serviceradar-addons.slice",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("drop-in missing %q in:\n%s", want, got)
		}
	}

	// Only declared (non-zero) limits are emitted.
	partial := renderSystemdResourceDropIn(agentaddon.Resources{MemoryMaxBytes: 1024})
	if strings.Contains(partial, "CPUQuota") || strings.Contains(partial, "TasksMax") ||
		strings.Contains(partial, "Slice=") {
		t.Errorf("unset limits must not appear:\n%s", partial)
	}
	if !strings.Contains(partial, "MemoryMax=1024") {
		t.Errorf("MemoryMax should appear:\n%s", partial)
	}
}
