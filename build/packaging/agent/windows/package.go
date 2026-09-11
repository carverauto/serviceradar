package main

import (
	"context"
	"crypto/sha256"
	"debug/pe"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var errInvalidPackage = errors.New("invalid Windows agent package")

const (
	product = "serviceradar-agent"
	// wixUtilExtension provides util:ServiceConfig; CI installs the version
	// matching the pinned WiX toolset.
	wixUtilExtension = "WixToolset.Util.wixext"
	agentFileName    = "serviceradar-agent.exe"
	// srctlFileName is the enrollment CLI the UI's Windows command runs.
	srctlFileName    = "srctl.exe"
	configFileName   = "agent.json"
	inputsFileName   = "inputs.json"
	packagerFileName = "package.exe"
)

// upgradeCodes identify each architecture's product line to Windows Installer.
// They must never change: MajorUpgrade finds the installed version through them.
var upgradeCodes = map[string]string{
	"amd64": "3B42E26D-C52D-43A8-AFD9-DDC162D2A6B3",
	"arm64": "FE1549BF-9F21-45FF-95D3-05AC0AEE9C3A",
}

var (
	architectures = []string{"amd64", "arm64"}
	wixArch       = map[string]string{"amd64": "x64", "arm64": "arm64"}
	peMachine     = map[string]uint16{"amd64": pe.IMAGE_FILE_MACHINE_AMD64, "arm64": pe.IMAGE_FILE_MACHINE_ARM64}

	versionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(pre|rc|alpha|beta)(0|[1-9][0-9]*))?$`)
	commitPattern  = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

func agentInputName(arch string) string { return "serviceradar-agent-" + arch + ".exe" }

func srctlInputName(arch string) string { return "srctl-" + arch + ".exe" }

// stagedInputs is inputs.json: what stage copied, so build can prove it is
// packaging exactly those bytes.
type stagedInputs struct {
	SchemaVersion int               `json:"schema_version"`
	Version       string            `json:"version"`
	SourceCommit  string            `json:"source_commit"`
	Files         map[string]string `json:"files"`
}

type provenance struct {
	SchemaVersion   int    `json:"schema_version"`
	Product         string `json:"product"`
	Version         string `json:"version"`
	MSIVersion      string `json:"msi_version"`
	SourceCommit    string `json:"source_commit"`
	OS              string `json:"os"`
	Arch            string `json:"arch"`
	Mode            string `json:"mode"`
	Signed          bool   `json:"signed"`
	UpgradeCode     string `json:"upgrade_code"`
	PackageFilename string `json:"package_filename"`
	PackageSHA256   string `json:"package_sha256"`
	BinarySHA256    string `json:"binary_sha256"`
	CLIBinarySHA256 string `json:"cli_binary_sha256"`
	ConfigSHA256    string `json:"config_sha256"`
}

type buildOptions struct{ InputDir, OutputDir, SourceCommit, Version, Wix string }
type output struct{ MSIPath, ProvenancePath string }

type commandRunner interface {
	run(ctx context.Context, name string, args ...string) ([]byte, error)
}

type systemRunner struct{}

// run returns tool output on failure: nothing here is secret (the MSI is
// unsigned), and WiX's messages are the only diagnosis.
func (systemRunner) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	data, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil {
		return data, fmt.Errorf("%s failed: %w\n%s", filepath.Base(name), err, data)
	}

	return data, nil
}

type builder struct {
	runner commandRunner
	// hostArch is the architecture whose agent can be executed for a
	// --version check on this host.
	hostArch string
}

func (b builder) build(ctx context.Context, opts buildOptions) ([]output, error) {
	if err := validateRelease(opts.Version, opts.SourceCommit); err != nil {
		return nil, err
	}

	if err := validateOutputDir(opts.OutputDir); err != nil {
		return nil, err
	}

	// msiexec parses TARGETDIR itself and does not honor the quoting Go applies.
	if strings.ContainsAny(opts.OutputDir, " \t") {
		return nil, fmt.Errorf("%w: output-dir must not contain whitespace", errInvalidPackage)
	}

	manifest, err := readStagedInputs(opts.InputDir)
	if err != nil {
		return nil, err
	}

	if manifest.Version != opts.Version || manifest.SourceCommit != opts.SourceCommit {
		return nil, fmt.Errorf("%w: staged inputs are for %s@%s, not %s@%s", errInvalidPackage,
			manifest.Version, manifest.SourceCommit, opts.Version, opts.SourceCommit)
	}

	msiVer, err := msiVersion(opts.Version)
	if err != nil {
		return nil, err
	}

	outs := make([]output, 0, len(architectures))

	for _, arch := range architectures {
		out, err := b.buildArch(ctx, opts, manifest, msiVer, arch)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", arch, err)
		}

		outs = append(outs, out)
	}

	return outs, nil
}

func (b builder) buildArch(ctx context.Context, opts buildOptions, manifest stagedInputs, msiVer, arch string) (output, error) {
	agent := filepath.Join(opts.InputDir, agentInputName(arch))
	srctl := filepath.Join(opts.InputDir, srctlInputName(arch))
	config := filepath.Join(opts.InputDir, configFileName)

	binarySHA, err := verifyStagedFile(manifest, opts.InputDir, agentInputName(arch))
	if err != nil {
		return output{}, err
	}

	configSHA, err := verifyStagedFile(manifest, opts.InputDir, configFileName)
	if err != nil {
		return output{}, err
	}

	srctlSHA, err := verifyStagedFile(manifest, opts.InputDir, srctlInputName(arch))
	if err != nil {
		return output{}, err
	}

	if err := verifyPE(agent, arch); err != nil {
		return output{}, err
	}

	if err := verifyPE(srctl, arch); err != nil {
		return output{}, fmt.Errorf("srctl: %w", err)
	}

	if arch == b.hostArch {
		data, err := b.runner.run(ctx, agent, "--version")
		if err != nil {
			return output{}, err
		}

		if strings.TrimRight(string(data), "\r\n") != opts.Version {
			return output{}, fmt.Errorf("%w: agent --version does not match the committed FULL_VERSION", errInvalidPackage)
		}
	}

	name := fmt.Sprintf("serviceradar-agent_%s_windows_%s", opts.Version, arch)
	out := output{filepath.Join(opts.OutputDir, name+".msi"), filepath.Join(opts.OutputDir, name+".provenance.json")}

	for _, path := range []string{out.MSIPath, out.ProvenancePath} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			return output{}, fmt.Errorf("%w: refusing to replace an existing output", errInvalidPackage)
		}
	}

	work, err := os.MkdirTemp(opts.OutputDir, ".agent-msi-")
	if err != nil {
		return output{}, err
	}
	defer func() { _ = os.RemoveAll(work) }()

	source, err := renderWXS(wxsValues{MSIVersion: msiVer, UpgradeCode: upgradeCodes[arch], AgentPath: agent, SrctlPath: srctl, ConfigPath: config})
	if err != nil {
		return output{}, err
	}

	wxs := filepath.Join(work, "agent.wxs")
	if err := os.WriteFile(wxs, source, 0o600); err != nil {
		return output{}, err
	}

	msi := filepath.Join(work, name+".msi")
	if _, err := b.runner.run(ctx, opts.Wix, "build", "-arch", wixArch[arch], "-ext", wixUtilExtension, "-o", msi, wxs); err != nil {
		return output{}, err
	}

	// An administrative install unpacks the MSI without registering anything,
	// which proves the package carries exactly the verified bytes.
	extract := filepath.Join(work, "extract")
	if _, err := b.runner.run(ctx, "msiexec", "/a", msi, "/qn", "TARGETDIR="+extract); err != nil {
		return output{}, err
	}

	if err := verifyExtracted(extract, map[string]string{agentFileName: binarySHA, srctlFileName: srctlSHA, configFileName: configSHA}); err != nil {
		return output{}, err
	}

	msiSHA, err := fileSHA256(msi)
	if err != nil {
		return output{}, err
	}

	proof := provenance{
		SchemaVersion: 1, Product: product, Version: opts.Version, MSIVersion: msiVer,
		SourceCommit: opts.SourceCommit, OS: "windows", Arch: arch, Mode: "unsigned", Signed: false,
		UpgradeCode: upgradeCodes[arch], PackageFilename: filepath.Base(out.MSIPath),
		PackageSHA256: msiSHA, BinarySHA256: binarySHA, CLIBinarySHA256: srctlSHA, ConfigSHA256: configSHA,
	}

	if err := exportResult(msi, out, proof); err != nil {
		return output{}, err
	}

	return out, nil
}

// msiVersion maps the release version onto Windows Installer's numeric
// ProductVersion (major and minor at most 255, build at most 65535). A
// prerelease maps to its final version; same-version upgrades are allowed so
// the final release replaces it.
func msiVersion(version string) (string, error) {
	m := versionPattern.FindStringSubmatch(version)
	if m == nil {
		return "", fmt.Errorf("%w: version %q is not major.minor.patch", errInvalidPackage, version)
	}

	limits := []int{255, 255, 65535}
	for i, limit := range limits {
		n, err := strconv.Atoi(m[i+1])
		if err != nil || n > limit {
			return "", fmt.Errorf("%w: version %q exceeds the Windows Installer version range", errInvalidPackage, version)
		}
	}

	return m[1] + "." + m[2] + "." + m[3], nil
}

func validateRelease(version, commit string) error {
	if !versionPattern.MatchString(version) {
		return fmt.Errorf("%w: the committed version must be major.minor.patch with an optional pre, rc, alpha, or beta number", errInvalidPackage)
	}

	if !commitPattern.MatchString(commit) {
		return fmt.Errorf("%w: source-commit must be a full lowercase commit SHA", errInvalidPackage)
	}

	return nil
}

func validateOutputDir(dir string) error {
	if !filepath.IsAbs(dir) {
		return fmt.Errorf("%w: output-dir must be absolute", errInvalidPackage)
	}

	clean, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return fmt.Errorf("output-dir must already exist: %w", err)
	}

	for _, part := range strings.Split(filepath.Clean(clean), string(filepath.Separator)) {
		if part == "bazel-out" || strings.HasSuffix(part, ".runfiles") {
			return fmt.Errorf("%w: output-dir must be outside the Bazel output tree", errInvalidPackage)
		}
	}

	return nil
}

func readStagedInputs(dir string) (stagedInputs, error) {
	var manifest stagedInputs

	data, err := os.ReadFile(filepath.Join(dir, inputsFileName))
	if err != nil {
		return manifest, fmt.Errorf("read staged inputs: %w", err)
	}

	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, fmt.Errorf("parse staged inputs: %w", err)
	}

	if manifest.SchemaVersion != 1 {
		return manifest, fmt.Errorf("%w: unsupported staged inputs schema %d", errInvalidPackage, manifest.SchemaVersion)
	}

	return manifest, nil
}

func verifyStagedFile(manifest stagedInputs, dir, name string) (string, error) {
	want, ok := manifest.Files[name]
	if !ok {
		return "", fmt.Errorf("%w: staged inputs do not list %s", errInvalidPackage, name)
	}

	got, err := fileSHA256(filepath.Join(dir, name))
	if err != nil {
		return "", err
	}

	if got != want {
		return "", fmt.Errorf("%w: %s differs from the staged input", errInvalidPackage, name)
	}

	return got, nil
}

func verifyPE(path, arch string) error {
	f, err := pe.Open(path)
	if err != nil {
		return fmt.Errorf("agent is not a PE executable: %w", err)
	}
	defer func() { _ = f.Close() }()

	if f.Machine != peMachine[arch] || f.Characteristics&pe.IMAGE_FILE_EXECUTABLE_IMAGE == 0 {
		return fmt.Errorf("%w: agent must be a Windows %s executable", errInvalidPackage, arch)
	}

	return nil
}

// verifyExtracted requires exactly one extracted file per expected name, with
// the expected contents.
func verifyExtracted(root string, want map[string]string) error {
	found := map[string][]string{}

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		if _, ok := want[d.Name()]; ok && d.Type().IsRegular() {
			found[d.Name()] = append(found[d.Name()], path)
		}

		return nil
	})
	if err != nil {
		return err
	}

	for name, sum := range want {
		if len(found[name]) != 1 {
			return fmt.Errorf("%w: the MSI must contain exactly one %s, found %d", errInvalidPackage, name, len(found[name]))
		}

		got, err := fileSHA256(found[name][0])
		if err != nil {
			return err
		}

		if got != sum {
			return fmt.Errorf("%w: packaged %s differs from its verified input", errInvalidPackage, name)
		}
	}

	return nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

func copyFile(source, target string, mode os.FileMode) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()

	info, err := in.Stat()
	if err != nil {
		return err
	}

	if !info.Mode().IsRegular() {
		return fmt.Errorf("%w: package input must be a regular file", errInvalidPackage)
	}

	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}

	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()

	if copyErr != nil {
		return copyErr
	}

	return closeErr
}

// exportResult hard-links the verified MSI and its provenance into place, so
// outputs appear complete and never replace another invocation's files.
func exportResult(msi string, out output, proof provenance) error {
	data, err := json.MarshalIndent(proof, "", "  ")
	if err != nil {
		return err
	}

	stagedProof := filepath.Join(filepath.Dir(msi), "provenance.json")
	if err := os.WriteFile(stagedProof, append(data, '\n'), 0o644); err != nil {
		return err
	}

	if err := os.Link(msi, out.MSIPath); err != nil {
		return err
	}

	if err := os.Link(stagedProof, out.ProvenancePath); err != nil {
		_ = os.Remove(out.MSIPath)

		return err
	}

	return nil
}
