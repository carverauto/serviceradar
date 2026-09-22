package main

import (
	"debug/elf"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const linuxARM64 = "arm64"

var (
	errReleasePlatformInputs = errors.New("invalid release platform inputs")
	errMacOSProvenance       = errors.New("invalid macOS installer provenance")
	errWindowsProvenance     = errors.New("invalid Windows installer provenance")
	errRuntimePlatform       = errors.New("invalid managed runtime platform")
)

type managedAgentRuntime struct {
	arch string
	path string
	url  string
}

type macOSSigningEvidence struct {
	Identity        string `json:"identity"`
	TeamID          string `json:"team_id"`
	HardenedRuntime bool   `json:"hardened_runtime"`
	Timestamp       bool   `json:"timestamp"`
	Verified        bool   `json:"verified"`
}

type macOSPackageProvenance struct {
	SchemaVersion      int                  `json:"schema_version"`
	Product            string               `json:"product"`
	Version            string               `json:"version"`
	SourceCommit       string               `json:"source_commit"`
	OS                 string               `json:"os"`
	Arch               string               `json:"arch"`
	Mode               string               `json:"mode"`
	PackageFilename    string               `json:"package_filename"`
	PackageSHA256      string               `json:"package_sha256"`
	BinarySHA256       string               `json:"binary_sha256"`
	ApplicationSigning macOSSigningEvidence `json:"application_signing"`
	InstallerSigning   macOSSigningEvidence `json:"installer_signing"`
	Notarization       struct {
		Status       string `json:"status"`
		SubmissionID string `json:"submission_id"`
		Stapled      bool   `json:"stapled"`
		Validated    bool   `json:"validated"`
	} `json:"notarization"`
	GatekeeperVerified bool `json:"gatekeeper_verified"`
}

// windowsUpgradeCodes must match build/packaging/agent/windows. An MSI carrying
// another UpgradeCode would install beside earlier agents instead of over them.
var windowsUpgradeCodes = map[string]string{
	"amd64": "3B42E26D-C52D-43A8-AFD9-DDC162D2A6B3",
	"arm64": "FE1549BF-9F21-45FF-95D3-05AC0AEE9C3A",
}

type windowsPackageProvenance struct {
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
	ConfigSHA256    string `json:"config_sha256"`
}

func prepareReleaseArtifacts(ctx *publishContext) error {
	if !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(ctx.config.commit) {
		return fmt.Errorf("%w: --commit must identify the exact 40-character release source commit", errReleasePlatformInputs)
	}
	version, err := readMaybeRunfile(ctx.resolver, "VERSION")
	if err != nil {
		return err
	}
	if strings.TrimSpace(version) != ctx.releaseVersion {
		return fmt.Errorf("%w: declared VERSION does not match release tag %q", errReleasePlatformInputs, ctx.config.tag)
	}
	ctx.packages, err = preparePackageArtifacts(ctx)
	if err != nil {
		return err
	}
	for _, platform := range []struct{ arch, runfile string }{
		{defaultAgentRuntimeArch, defaultAgentRuntimeRunfile},
		{linuxARM64, arm64AgentRuntimeRunfile},
	} {
		path, err := ctx.resolver.resolve(platform.runfile)
		if err != nil {
			return fmt.Errorf("missing Linux %s runtime: %w", platform.arch, err)
		}
		if err := validateLinuxRuntimeArchive(path, platform.arch); err != nil {
			return fmt.Errorf("invalid Linux %s runtime: %w", platform.arch, err)
		}
		ctx.runtimes = append(ctx.runtimes, managedAgentRuntime{arch: platform.arch, path: path})
	}
	if !ctx.config.dryRun {
		_, err = managedAgentReleasePrivateKey()
	}
	return err
}

func preparePackageArtifacts(ctx *publishContext) ([]uploadAsset, error) {
	paths, err := collectAssets(ctx.resolver, ctx.config.manifestPath)
	if err != nil {
		return nil, err
	}
	assets := make([]uploadAsset, 0, len(paths)+1)
	names := make(map[string]bool, len(paths))
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() == 0 {
			return nil, fmt.Errorf("%w: package %q must be a nonempty regular file", errReleasePlatformInputs, path)
		}
		name, err := resolveUploadName(path, ctx.releaseVersion, ctx.rpmVersion, ctx.rpmRelease)
		if err != nil {
			return nil, err
		}
		if names[name] {
			return nil, fmt.Errorf("%w: duplicate package asset %q", errReleasePlatformInputs, name)
		}
		names[name] = true
		assets = append(assets, uploadAsset{sourcePath: path, uploadName: name})
	}
	for _, name := range requiredLinuxAgentPackages(ctx.releaseVersion, ctx.rpmVersion, ctx.rpmRelease) {
		if !names[name] {
			return nil, fmt.Errorf("%w: required Linux agent package %q is missing", errReleasePlatformInputs, name)
		}
	}
	switch {
	case ctx.config.macosPkg == "" && ctx.config.macosProvenance == "":
		// The macOS job no longer gates a release; release.yml omits both flags when it failed.
		fmt.Fprintln(os.Stderr, "warning: publishing without the macOS installer: --macos_pkg and --macos_provenance were not given")
	case ctx.config.macosPkg == "" || ctx.config.macosProvenance == "":
		return nil, fmt.Errorf("%w: pass --macos_pkg and --macos_provenance together, or neither", errMacOSProvenance)
	default:
		macOS, err := validateMacOSPackage(ctx.config, ctx.releaseVersion)
		if err != nil {
			return nil, err
		}
		assets = append(assets, macOS, uploadAsset{
			sourcePath: ctx.config.macosProvenance,
			uploadName: strings.TrimSuffix(macOS.uploadName, ".pkg") + ".provenance.json",
		})
	}
	windows, err := validateWindowsPackages(ctx.config, ctx.releaseVersion)
	if err != nil {
		return nil, err
	}
	return append(assets, windows...), nil
}

func requiredLinuxAgentPackages(version, rpmVersion, rpmRelease string) []string {
	return []string{
		fmt.Sprintf("serviceradar-agent_%s_amd64.deb", version),
		fmt.Sprintf("serviceradar-agent_%s_arm64.deb", version),
		fmt.Sprintf("serviceradar-agent-%s-%s.x86_64.rpm", rpmVersion, rpmRelease),
		fmt.Sprintf("serviceradar-agent-%s-%s.aarch64.rpm", rpmVersion, rpmRelease),
	}
}

func validateMacOSPackage(config publishConfig, version string) (uploadAsset, error) {
	if !filepath.IsAbs(config.macosPkg) || !filepath.IsAbs(config.macosProvenance) {
		return uploadAsset{}, fmt.Errorf("%w: --macos_pkg and --macos_provenance must be absolute paths to the verified CI handoff", errMacOSProvenance)
	}
	data, err := os.ReadFile(config.macosProvenance)
	if err != nil {
		return uploadAsset{}, err
	}
	var proof macOSPackageProvenance
	if err := json.Unmarshal(data, &proof); err != nil {
		return uploadAsset{}, err
	}
	name := fmt.Sprintf("serviceradar-agent_%s_darwin_arm64.pkg", version)
	if proof.SchemaVersion != 1 || proof.Product != defaultAgentRuntimeEntrypoint || proof.Mode != "release" ||
		proof.Version != version || proof.SourceCommit != config.commit || proof.OS != "darwin" || proof.Arch != linuxARM64 ||
		proof.PackageFilename != name || filepath.Base(config.macosPkg) != name {
		return uploadAsset{}, fmt.Errorf("%w: macOS installer provenance does not match the release source, version, platform, or filename", errMacOSProvenance)
	}
	if err := validateMacOSSigningEvidence(proof); err != nil {
		return uploadAsset{}, err
	}
	info, err := os.Stat(config.macosPkg)
	if err != nil {
		return uploadAsset{}, err
	}
	if !info.Mode().IsRegular() || info.Size() == 0 {
		return uploadAsset{}, fmt.Errorf("%w: macOS installer must be a nonempty regular file", errMacOSProvenance)
	}
	digest, err := fileSHA256(config.macosPkg)
	if err != nil {
		return uploadAsset{}, err
	}
	if digest != proof.PackageSHA256 {
		return uploadAsset{}, fmt.Errorf("%w: macOS installer SHA256 differs from its verified CI provenance", errMacOSProvenance)
	}
	return uploadAsset{sourcePath: config.macosPkg, uploadName: name}, nil
}

// validateWindowsPackages checks both MSIs against the provenance the Windows
// packaging job wrote. Unsigned is the only accepted mode until Authenticode
// signing exists (#388).
func validateWindowsPackages(config publishConfig, version string) ([]uploadAsset, error) {
	if !filepath.IsAbs(config.windowsDir) {
		return nil, fmt.Errorf("%w: --windows_dir must be an absolute path to the verified CI handoff", errWindowsProvenance)
	}
	sha256Hex := regexp.MustCompile(`^[a-f0-9]{64}$`)
	var assets []uploadAsset
	for _, arch := range []string{defaultAgentRuntimeArch, linuxARM64} {
		name := fmt.Sprintf("serviceradar-agent_%s_windows_%s.msi", version, arch)
		msi := filepath.Join(config.windowsDir, name)
		proofPath := strings.TrimSuffix(msi, ".msi") + ".provenance.json"
		data, err := os.ReadFile(proofPath)
		if err != nil {
			return nil, err
		}
		var proof windowsPackageProvenance
		if err := json.Unmarshal(data, &proof); err != nil {
			return nil, err
		}
		if proof.SchemaVersion != 1 || proof.Product != defaultAgentRuntimeEntrypoint || proof.Version != version ||
			proof.SourceCommit != config.commit || proof.OS != "windows" || proof.Arch != arch ||
			proof.Mode != "unsigned" || proof.Signed || proof.UpgradeCode != windowsUpgradeCodes[arch] ||
			proof.PackageFilename != name || !sha256Hex.MatchString(proof.BinarySHA256) || !sha256Hex.MatchString(proof.ConfigSHA256) {
			return nil, fmt.Errorf("%w: %s provenance does not match the release source, version, platform, filename, or upgrade code", errWindowsProvenance, name)
		}
		info, err := os.Stat(msi)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() == 0 {
			return nil, fmt.Errorf("%w: %s must be a nonempty regular file", errWindowsProvenance, name)
		}
		digest, err := fileSHA256(msi)
		if err != nil {
			return nil, err
		}
		if digest != proof.PackageSHA256 {
			return nil, fmt.Errorf("%w: %s SHA256 differs from its CI provenance", errWindowsProvenance, name)
		}
		assets = append(assets,
			uploadAsset{sourcePath: msi, uploadName: name},
			uploadAsset{sourcePath: proofPath, uploadName: strings.TrimSuffix(name, ".msi") + ".provenance.json"})
	}
	return assets, nil
}

func validateMacOSSigningEvidence(proof macOSPackageProvenance) error {
	app, installer, notary := proof.ApplicationSigning, proof.InstallerSigning, proof.Notarization
	if !app.Verified || !app.HardenedRuntime || !app.Timestamp || app.Identity == "" || app.TeamID == "" ||
		!installer.Verified || !installer.Timestamp || installer.Identity == "" || installer.TeamID != app.TeamID ||
		notary.Status != "Accepted" || notary.SubmissionID == "" || !notary.Stapled || !notary.Validated ||
		!proof.GatekeeperVerified || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(proof.BinarySHA256) {
		return fmt.Errorf("%w: macOS installer lacks complete application, installer, notarization, or Gatekeeper verification", errMacOSProvenance)
	}
	return nil
}

func validateLinuxRuntimeArchive(path, arch string) error {
	dir, err := os.MkdirTemp("", "serviceradar-runtime-validation-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	binary := filepath.Join(dir, defaultAgentRuntimeEntrypoint)
	if err := extractAgentTestRuntime(path, binary); err != nil {
		return err
	}
	executable, err := elf.Open(binary)
	if err != nil {
		return err
	}
	defer func() { _ = executable.Close() }()
	want := map[string]elf.Machine{defaultAgentRuntimeArch: elf.EM_X86_64, linuxARM64: elf.EM_AARCH64}[arch]
	if want == elf.EM_NONE || executable.Machine != want || executable.Class != elf.ELFCLASS64 {
		return fmt.Errorf("%w: ELF architecture %s does not match Linux %s", errRuntimePlatform, executable.Machine, arch)
	}
	return nil
}

func linuxAgentRuntimeUploadName(version, arch string) string {
	return fmt.Sprintf("serviceradar-agent_%s_linux_%s.tar.gz", version, arch)
}

func managedLinuxManifestArtifacts(runtimes []managedAgentRuntime) ([]agentReleaseManifestArtifact, error) {
	if len(runtimes) != 2 {
		return nil, fmt.Errorf("%w: managed release requires exactly Linux amd64 and arm64 runtimes", errRuntimePlatform)
	}
	artifacts := make([]agentReleaseManifestArtifact, 0, 2)
	seen := make(map[string]bool, 2)
	for _, runtime := range runtimes {
		if (runtime.arch != defaultAgentRuntimeArch && runtime.arch != linuxARM64) || seen[runtime.arch] || runtime.url == "" {
			return nil, fmt.Errorf("%w: managed runtime platform is missing, duplicated, or unsupported", errRuntimePlatform)
		}
		seen[runtime.arch] = true
		digest, err := fileSHA256(runtime.path)
		if err != nil {
			return nil, err
		}
		artifact := baseAgentManifestArtifact(runtime.url, digest)
		artifact.Arch = runtime.arch
		artifacts = append(artifacts, artifact)
	}
	sort.Slice(artifacts, func(i, j int) bool { return artifacts[i].Arch < artifacts[j].Arch })
	return artifacts, nil
}
