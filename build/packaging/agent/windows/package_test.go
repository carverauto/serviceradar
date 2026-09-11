package main

import (
	"context"
	"debug/pe"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testVersion = "2.3.4"
	testCommit  = "0123456789abcdef0123456789abcdef01234567"
)

var errSyntheticTool = errors.New("synthetic tool failure")

// writePE writes a minimal PE header that debug/pe accepts.
func writePE(t *testing.T, path string, machine uint16) {
	t.Helper()

	buf := make([]byte, 0x40)
	copy(buf, "MZ")
	binary.LittleEndian.PutUint32(buf[0x3c:], 0x40)
	buf = append(buf, 'P', 'E', 0, 0)

	header := make([]byte, 20)
	binary.LittleEndian.PutUint16(header[0:], machine)
	binary.LittleEndian.PutUint16(header[18:], pe.IMAGE_FILE_EXECUTABLE_IMAGE)
	buf = append(buf, header...)
	buf = append(buf, []byte("synthetic agent "+fmt.Sprint(machine))...)

	if err := os.WriteFile(path, buf, 0o755); err != nil {
		t.Fatal(err)
	}
}

type fakeTools struct {
	t       *testing.T
	calls   []string
	mutate  string
	version string
}

func (f *fakeTools) run(_ context.Context, name string, args ...string) ([]byte, error) {
	tool := filepath.Base(name)
	f.calls = append(f.calls, tool+" "+strings.Join(args, " "))

	switch {
	case strings.HasPrefix(tool, "serviceradar-agent-"):
		if f.mutate == "version" {
			return []byte("0.0.0\r\n"), nil
		}

		return []byte(testVersion + "\r\n"), nil
	case tool == "wix":
		if f.mutate == "wix" {
			return nil, errSyntheticTool
		}

		wxs, err := os.ReadFile(args[len(args)-1])
		if err != nil {
			return nil, err
		}

		// Record the rendered sources so msiexec can "extract" them.
		out := ""
		for i := range args[:len(args)-1] {
			if args[i] == "-o" {
				out = args[i+1]
			}
		}

		if !strings.Contains(strings.Join(args, " "), "-ext "+wixUtilExtension) {
			return nil, fmt.Errorf("%w: wix build without the Util extension", errSyntheticTool)
		}

		return nil, os.WriteFile(out, wxs, 0o644)
	case tool == "msiexec":
		wxs, err := os.ReadFile(args[1])
		if err != nil {
			return nil, err
		}

		target := strings.TrimPrefix(args[3], "TARGETDIR=")
		agent := between(string(wxs), `<File Id="AgentExe" Source="`, `"`)
		srctl := between(string(wxs), `<File Id="SrctlExe" Source="`, `"`)
		config := between(string(wxs), `<File Id="AgentConfig" Source="`, `"`)

		for _, file := range []struct{ source, dir, name string }{
			{agent, "PFiles64/ServiceRadar", agentFileName},
			{srctl, "PFiles64/ServiceRadar", srctlFileName},
			{config, "CommonAppData/ServiceRadar/config", configFileName},
		} {
			data, err := os.ReadFile(file.source)
			if err != nil {
				return nil, err
			}

			if (f.mutate == "extracted" && file.name == agentFileName) || (f.mutate == "extracted-srctl" && file.name == srctlFileName) {
				data = append(data, 'x')
			}

			dir := filepath.Join(target, filepath.FromSlash(file.dir))
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, err
			}

			if err := os.WriteFile(filepath.Join(dir, file.name), data, 0o644); err != nil {
				return nil, err
			}
		}

		return nil, nil
	default:
		return nil, fmt.Errorf("%w: unexpected command %s", errSyntheticTool, tool)
	}
}

func between(s, start, end string) string {
	i := strings.Index(s, start)
	if i < 0 {
		return ""
	}

	rest := s[i+len(start):]

	return rest[:strings.Index(rest, end)]
}

func stageFixture(t *testing.T) (string, stageInputs) {
	t.Helper()

	src := t.TempDir()
	in := stageInputs{
		AgentAMD64: filepath.Join(src, "amd64.exe"),
		AgentARM64: filepath.Join(src, "arm64.exe"),
		SrctlAMD64: filepath.Join(src, "srctl-amd64.exe"),
		SrctlARM64: filepath.Join(src, "srctl-arm64.exe"),
		Config:     filepath.Join(src, "agent.json"),
		Packager:   filepath.Join(src, "package.exe"),
	}
	writePE(t, in.AgentAMD64, pe.IMAGE_FILE_MACHINE_AMD64)
	writePE(t, in.AgentARM64, pe.IMAGE_FILE_MACHINE_ARM64)
	writePE(t, in.SrctlAMD64, pe.IMAGE_FILE_MACHINE_AMD64)
	writePE(t, in.SrctlARM64, pe.IMAGE_FILE_MACHINE_ARM64)

	for _, path := range []string{in.Config, in.Packager} {
		if err := os.WriteFile(path, []byte("synthetic "+filepath.Base(path)), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	staged := t.TempDir()
	if err := stage(staged, testVersion, testCommit, in); err != nil {
		t.Fatalf("stage: %v", err)
	}

	return staged, in
}

func buildFixture(t *testing.T, tools *fakeTools) ([]output, string, error) {
	t.Helper()

	staged, _ := stageFixture(t)
	outDir := t.TempDir()
	opts := buildOptions{InputDir: staged, OutputDir: outDir, SourceCommit: testCommit, Version: testVersion, Wix: "wix"}
	outs, err := builder{runner: tools, hostArch: "amd64"}.build(context.Background(), opts)

	return outs, staged, err
}

func TestStageRecordsDigestsOfDeclaredInputs(t *testing.T) {
	staged, in := stageFixture(t)

	manifest, err := readStagedInputs(staged)
	if err != nil {
		t.Fatal(err)
	}

	if manifest.Version != testVersion || manifest.SourceCommit != testCommit {
		t.Fatalf("manifest = %+v", manifest)
	}

	want, err := fileSHA256(in.AgentARM64)
	if err != nil {
		t.Fatal(err)
	}

	if manifest.Files[agentInputName("arm64")] != want {
		t.Fatalf("arm64 digest = %q, want %q", manifest.Files[agentInputName("arm64")], want)
	}

	if len(manifest.Files) != 6 {
		t.Fatalf("staged %d files, want 6", len(manifest.Files))
	}
}

func TestStageRejectsWrongArchitectureAgent(t *testing.T) {
	src := t.TempDir()
	in := stageInputs{
		AgentAMD64: filepath.Join(src, "amd64.exe"), AgentARM64: filepath.Join(src, "arm64.exe"),
		SrctlAMD64: filepath.Join(src, "srctl-amd64.exe"), SrctlARM64: filepath.Join(src, "srctl-arm64.exe"),
		Config: filepath.Join(src, "agent.json"), Packager: filepath.Join(src, "package.exe"),
	}
	writePE(t, in.AgentAMD64, pe.IMAGE_FILE_MACHINE_AMD64)
	writePE(t, in.AgentARM64, pe.IMAGE_FILE_MACHINE_AMD64)
	writePE(t, in.SrctlAMD64, pe.IMAGE_FILE_MACHINE_AMD64)
	writePE(t, in.SrctlARM64, pe.IMAGE_FILE_MACHINE_ARM64)

	for _, path := range []string{in.Config, in.Packager} {
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := stage(t.TempDir(), testVersion, testCommit, in); !errors.Is(err, errInvalidPackage) {
		t.Fatalf("stage accepted an amd64 binary as the arm64 agent: %v", err)
	}
}

func TestBuildProducesVerifiedMSIsForBothArchitectures(t *testing.T) {
	tools := &fakeTools{t: t}

	outs, staged, err := buildFixture(t, tools)
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	if len(outs) != 2 {
		t.Fatalf("built %d MSIs, want 2", len(outs))
	}

	for i, arch := range architectures {
		wantName := fmt.Sprintf("serviceradar-agent_%s_windows_%s.msi", testVersion, arch)
		if filepath.Base(outs[i].MSIPath) != wantName {
			t.Fatalf("MSI name = %q, want %q", filepath.Base(outs[i].MSIPath), wantName)
		}

		data, err := os.ReadFile(outs[i].ProvenancePath)
		if err != nil {
			t.Fatal(err)
		}

		var proof provenance
		if err := json.Unmarshal(data, &proof); err != nil {
			t.Fatal(err)
		}

		binary, _ := fileSHA256(filepath.Join(staged, agentInputName(arch)))
		msi, _ := fileSHA256(outs[i].MSIPath)

		if proof.Arch != arch || proof.OS != "windows" || proof.Signed || proof.Mode != "unsigned" ||
			proof.Version != testVersion || proof.MSIVersion != testVersion || proof.SourceCommit != testCommit ||
			proof.UpgradeCode != upgradeCodes[arch] || proof.BinarySHA256 != binary || proof.PackageSHA256 != msi {
			t.Fatalf("provenance for %s = %+v", arch, proof)
		}
	}

	wantWix := map[string]bool{"x64": false, "arm64": false}
	versionChecks := 0

	for _, call := range tools.calls {
		for arch := range wantWix {
			if strings.HasPrefix(call, "wix build -arch "+arch+" ") {
				wantWix[arch] = true
			}
		}

		if strings.HasPrefix(call, "serviceradar-agent-") {
			versionChecks++
		}
	}

	if !wantWix["x64"] || !wantWix["arm64"] {
		t.Fatalf("wix was not run for both architectures: %v", tools.calls)
	}

	if versionChecks != 1 {
		t.Fatalf("ran --version %d times; only the host-architecture agent can execute", versionChecks)
	}
}

func TestBuildFailsClosed(t *testing.T) {
	for _, mutate := range []string{"version", "wix", "extracted", "extracted-srctl"} {
		t.Run(mutate, func(t *testing.T) {
			outs, _, err := buildFixture(t, &fakeTools{t: t, mutate: mutate})
			if err == nil || outs != nil {
				t.Fatalf("build succeeded with mutation %q", mutate)
			}
		})
	}
}

func TestBuildRejectsTamperedStagedInput(t *testing.T) {
	staged, _ := stageFixture(t)

	if err := os.WriteFile(filepath.Join(staged, configFileName), []byte("tampered"), 0o644); err != nil {
		t.Fatal(err)
	}

	opts := buildOptions{InputDir: staged, OutputDir: t.TempDir(), SourceCommit: testCommit, Version: testVersion, Wix: "wix"}
	if _, err := (builder{runner: &fakeTools{t: t}, hostArch: "amd64"}).build(context.Background(), opts); !errors.Is(err, errInvalidPackage) {
		t.Fatalf("build accepted a staged input that differs from inputs.json: %v", err)
	}
}

func TestBuildRejectsInputsFromAnotherCommit(t *testing.T) {
	staged, _ := stageFixture(t)
	other := strings.Repeat("f", 40)

	opts := buildOptions{InputDir: staged, OutputDir: t.TempDir(), SourceCommit: other, Version: testVersion, Wix: "wix"}
	if _, err := (builder{runner: &fakeTools{t: t}, hostArch: "amd64"}).build(context.Background(), opts); !errors.Is(err, errInvalidPackage) {
		t.Fatalf("build accepted inputs staged from a different commit: %v", err)
	}
}

func TestBuildNeverReplacesExistingOutput(t *testing.T) {
	staged, _ := stageFixture(t)
	outDir := t.TempDir()
	existing := filepath.Join(outDir, fmt.Sprintf("serviceradar-agent_%s_windows_amd64.msi", testVersion))

	if err := os.WriteFile(existing, []byte("previous"), 0o644); err != nil {
		t.Fatal(err)
	}

	opts := buildOptions{InputDir: staged, OutputDir: outDir, SourceCommit: testCommit, Version: testVersion, Wix: "wix"}
	if _, err := (builder{runner: &fakeTools{t: t}, hostArch: "amd64"}).build(context.Background(), opts); !errors.Is(err, errInvalidPackage) {
		t.Fatalf("build replaced an existing MSI: %v", err)
	}
}

func TestMSIVersion(t *testing.T) {
	for version, want := range map[string]string{
		"1.4.58":        "1.4.58",
		"1.4.58-pre1":   "1.4.58",
		"255.255.65535": "255.255.65535",
	} {
		got, err := msiVersion(version)
		if err != nil || got != want {
			t.Errorf("msiVersion(%q) = %q, %v; want %q", version, got, err, want)
		}
	}

	for _, version := range []string{"1.4", "256.0.0", "1.256.0", "1.0.65536", "v1.4.58"} {
		if _, err := msiVersion(version); err == nil {
			t.Errorf("msiVersion(%q) accepted a version outside the Windows Installer range", version)
		}
	}
}

func TestWXSInstallsServiceWithoutStartingIt(t *testing.T) {
	src, err := renderWXS(wxsValues{MSIVersion: "1.2.3", UpgradeCode: upgradeCodes["amd64"], AgentPath: `C:\in\a.exe`, SrctlPath: `C:\in\srctl.exe`, ConfigPath: `C:\in\agent.json`})
	if err != nil {
		t.Fatal(err)
	}

	wxs := string(src)
	for _, want := range []string{
		`<ServiceInstall Name="ServiceRadarAgent"`,
		`Start="auto"`,
		`Account="LocalSystem"`,
		`<util:ServiceConfig FirstFailureActionType="restart" SecondFailureActionType="restart" ThirdFailureActionType="restart"`,
		`UpgradeCode="` + upgradeCodes["amd64"] + `"`,
		`NeverOverwrite="yes" Permanent="yes"`,
		`<MajorUpgrade AllowSameVersionUpgrades="yes"`,
		`<File Id="SrctlExe" Source="C:\in\srctl.exe" Name="srctl.exe"`,
		`<Environment Id="SrctlOnPath" Name="PATH" Value="[INSTALLFOLDER]" Action="set" Part="last" System="yes"`,
	} {
		if !strings.Contains(wxs, want) {
			t.Errorf("rendered WiX source lacks %s", want)
		}
	}

	control := between(wxs, `<ServiceControl Id="StopAndRemove"`, "/>")
	if control == "" || strings.Contains(control, "Start=") {
		t.Errorf("a fresh install must not start the service before it is configured: %q", control)
	}

	upgrade := between(wxs, `<Component Id="StartAfterUpgrade"`, "</Component>")
	if !strings.Contains(upgrade, `Condition="WIX_UPGRADE_DETECTED"`) || !strings.Contains(upgrade, `Start="install"`) {
		t.Errorf("an upgrade must restart the service it stopped: %q", upgrade)
	}
}

func TestWXSRejectsValuesNeedingEscaping(t *testing.T) {
	for _, bad := range []string{`C:\in\"a.exe`, `C:\in\a&b.exe`, "", `C:\in\<a>.exe`} {
		if _, err := renderWXS(wxsValues{MSIVersion: "1.2.3", UpgradeCode: upgradeCodes["amd64"], AgentPath: bad, SrctlPath: `C:\in\srctl.exe`, ConfigPath: `C:\c.json`}); err == nil {
			t.Errorf("renderWXS accepted %q", bad)
		}
	}
}

func TestUpgradeCodesAreStableAndDistinct(t *testing.T) {
	if upgradeCodes["amd64"] != "3B42E26D-C52D-43A8-AFD9-DDC162D2A6B3" || upgradeCodes["arm64"] != "FE1549BF-9F21-45FF-95D3-05AC0AEE9C3A" {
		t.Fatal("UpgradeCodes changed; installed agents would no longer be upgraded in place")
	}
}

func TestBuildRecordsTheShippedSrctl(t *testing.T) {
	outs, staged, err := buildFixture(t, &fakeTools{t: t})
	if err != nil {
		t.Fatalf("build: %v", err)
	}

	for i, arch := range architectures {
		data, err := os.ReadFile(outs[i].ProvenancePath)
		if err != nil {
			t.Fatal(err)
		}

		var proof provenance
		if err := json.Unmarshal(data, &proof); err != nil {
			t.Fatal(err)
		}

		want, _ := fileSHA256(filepath.Join(staged, srctlInputName(arch)))
		if proof.CLIBinarySHA256 == "" || proof.CLIBinarySHA256 != want {
			t.Fatalf("%s provenance srctl digest = %q, want %q", arch, proof.CLIBinarySHA256, want)
		}
	}
}
