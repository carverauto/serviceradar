package main

import (
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var (
	errInvalidPackage = errors.New("invalid macOS agent package")
	errCommandTimeout = errors.New("platform command timed out")
)

const (
	modeUnsigned  = "unsigned"
	modeRelease   = "release"
	packageID     = "com.serviceradar.agent"
	agentPayload  = "usr/local/libexec/serviceradar/serviceradar-agent"
	configPayload = "private/etc/serviceradar/agent.json"
	plistPayload  = "Library/LaunchDaemons/com.serviceradar.agent.plist"
	// srctl enrolls the agent (`srctl enroll`); the enrollment command the UI
	// shows names this path on every platform.
	srctlPayload = "usr/local/bin/srctl"
)

type options struct {
	Mode, OutputDir, SourceCommit, Version                  string
	Keychain, NotaryProfile, AppIdentity, InstallerIdentity string
}

type inputs struct{ Agent, Config, Plist, Preinstall, Postinstall, Srctl string }
type output struct{ PackagePath, ProvenancePath string }
type commandRunner interface {
	run(context.Context, string, ...string) ([]byte, error)
}
type builder struct{ runner commandRunner }
type systemRunner struct {
	env []string
	// limit overrides commandTimeout; tests set it to prove a hang fails fast.
	limit time.Duration
}

// commandTimeout bounds one platform command. A codesign or productsign that waits
// on a keychain access prompt never returns on a CI runner, and without a bound the
// release log shows nothing until the whole job is cancelled (v1.4.59 sat silent for
// 41 minutes). notarytool carries its own --timeout, so it gets a longer bound.
// xcrunTool is the binary notarytool and stapler run under.
const xcrunTool = "xcrun"

func commandTimeout(name string, args []string) time.Duration {
	if filepath.Base(name) == xcrunTool && len(args) > 0 && args[0] == "notarytool" {
		return 40 * time.Minute
	}
	return 5 * time.Minute
}

// commandStep names a command for the progress log: the tool and its first
// argument when that is a subcommand or flag, never an identity, path, or value.
func commandStep(name string, args []string) string {
	step := filepath.Base(name)
	if len(args) > 0 && !strings.ContainsAny(args[0], "/=:") {
		step += " " + args[0]
	}
	return step
}

func (r systemRunner) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	step := commandStep(name, args)
	limit := r.limit
	if limit == 0 {
		limit = commandTimeout(name, args)
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = r.env
	// Reap the command even if a child process keeps its output pipe open.
	cmd.WaitDelay = 10 * time.Second
	fmt.Fprintf(os.Stderr, "==> %s\n", step)
	started := time.Now()
	data, err := cmd.CombinedOutput()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil, fmt.Errorf("%s timed out after %s; on a CI runner this is usually a keychain access prompt or an unreachable Apple service: %w", filepath.Base(name), limit, errCommandTimeout)
	}
	if err != nil {
		// Platform output can include identity/keychain metadata. Return the exit status,
		// never the command arguments or raw output, on failure -- plus a cause from the
		// fixed vocabulary in signingFailureReason when the output names a known one.
		if reason := signingFailureReason(data); reason != "" {
			return nil, fmt.Errorf("%s failed: %s: %w", filepath.Base(name), reason, err)
		}
		return nil, fmt.Errorf("%s failed: %w", filepath.Base(name), err)
	}
	fmt.Fprintf(os.Stderr, "    %s done in %s\n", step, time.Since(started).Round(time.Second))
	return data, nil
}

const identityNotFound = "signing identity not found in the keychain: the configured identity must match the certificate's common name exactly"

// signingFailureReason returns the fixed description of the first known cause in
// output, or "" when none matches. It never returns any part of output.
//
// The tool's text is the only signal: codesign and productsign exit 1 for every one of
// these. The first match wins, so a specific cause precedes the symptom it produces --
// an incomplete chain is reported alongside errSecInternalComponent.
func signingFailureReason(output []byte) string {
	known := []struct{ needle, reason string }{
		{"no identity found", identityNotFound},
		{"could not be found in the keychain", identityNotFound},
		{"Could not find appropriate signing identity", identityNotFound},
		{"ambiguous (matches", "signing identity matches more than one certificate: configure the certificate's SHA-1 hash instead of its name"},
		{"unable to build chain to self-signed root", "certificate chain is incomplete: the Developer ID intermediate certificate is not available to the keychain"},
		{"errSecInternalComponent", "keychain denied access to the signing key (errSecInternalComponent): the keychain is locked or its key partition list omits the signing tool"},
		{"timestamp service is not available", "Apple timestamp service is unavailable"},
		{"detritus not allowed", "file carries extended attributes that signing refuses (resource fork or Finder information)"},
	}
	text := string(output)
	for _, cause := range known {
		if strings.Contains(text, cause.needle) {
			return cause.reason
		}
	}
	return ""
}

func platformEnvironment() []string {
	env := []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C"}
	for _, key := range []string{"HOME", "TMPDIR", "DEVELOPER_DIR"} {
		if value := os.Getenv(key); value != "" {
			env = append(env, key+"="+value)
		}
	}
	return env
}

func (o options) validate() error {
	if o.Mode != modeUnsigned && o.Mode != modeRelease {
		return fmt.Errorf("%w: mode must be unsigned or release", errInvalidPackage)
	}
	if !regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(pre|rc|alpha|beta)(0|[1-9][0-9]*))?$`).MatchString(o.Version) {
		return fmt.Errorf("%w: the committed version must be major.minor.patch with an optional pre, rc, alpha, or beta number", errInvalidPackage)
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(o.SourceCommit) {
		return fmt.Errorf("%w: source-commit must be a full lowercase commit SHA", errInvalidPackage)
	}
	if !filepath.IsAbs(o.OutputDir) {
		return fmt.Errorf("%w: output-dir must be absolute", errInvalidPackage)
	}
	clean, err := filepath.EvalSymlinks(o.OutputDir)
	if err != nil {
		return fmt.Errorf("output-dir must already exist: %w", err)
	}
	for _, part := range strings.Split(filepath.Clean(clean), string(filepath.Separator)) {
		if part == "bazel-out" || strings.HasSuffix(part, ".runfiles") {
			return fmt.Errorf("%w: output-dir must be outside the Bazel output tree", errInvalidPackage)
		}
	}
	if o.Mode == modeUnsigned {
		return nil
	}
	if !filepath.IsAbs(o.Keychain) || o.NotaryProfile == "" {
		return fmt.Errorf("%w: release requires an absolute keychain and notary-profile", errInvalidPackage)
	}
	if info, err := os.Stat(o.Keychain); err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("%w: release keychain must be an existing regular file", errInvalidPackage)
	}
	appTeam, err := identityTeam(o.AppIdentity, "Application")
	if err != nil {
		return err
	}
	installerTeam, err := identityTeam(o.InstallerIdentity, "Installer")
	if err != nil {
		return err
	}
	if appTeam != installerTeam {
		return fmt.Errorf("%w: application and installer identities must belong to the same team", errInvalidPackage)
	}
	return nil
}

func identityTeam(identity, kind string) (string, error) {
	m := regexp.MustCompile(`^Developer ID ` + kind + `: [^\r\n]+ \(([A-Z0-9]{10})\)$`).FindStringSubmatch(identity)
	if len(m) != 2 {
		return "", fmt.Errorf("%w: release requires a Developer ID %s identity", errInvalidPackage, kind)
	}
	return m[1], nil
}

func (b builder) build(ctx context.Context, opts options, in inputs) (output, error) {
	if err := opts.validate(); err != nil {
		return output{}, err
	}
	name := "serviceradar-agent_" + opts.Version + "_darwin_arm64"
	if opts.Mode == modeUnsigned {
		name += ".unsigned"
	}
	out := output{filepath.Join(opts.OutputDir, name+".pkg"), filepath.Join(opts.OutputDir, name+".provenance.json")}
	for _, path := range []string{out.PackagePath, out.ProvenancePath} {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			return output{}, fmt.Errorf("%w: refusing to replace an existing output", errInvalidPackage)
		}
	}
	work, err := os.MkdirTemp(opts.OutputDir, ".agent-pkg-")
	if err != nil {
		return output{}, err
	}
	defer func() { _ = os.RemoveAll(work) }()
	root := filepath.Join(work, "root")
	scripts := filepath.Join(work, "scripts")
	if err := stage(root, scripts, in); err != nil {
		return output{}, err
	}
	agent := filepath.Join(root, agentPayload)
	if err := verifyAgent(ctx, b.runner, agent, opts.Version); err != nil {
		return output{}, err
	}
	srctl := filepath.Join(root, srctlPayload)
	if err := verifyCLI(srctl); err != nil {
		return output{}, err
	}
	proof := provenance{SchemaVersion: 1, Product: "serviceradar-agent", Version: opts.Version, SourceCommit: opts.SourceCommit, OS: "darwin", Arch: "arm64", Mode: opts.Mode, PackageFilename: filepath.Base(out.PackagePath)}
	if opts.Mode == modeRelease {
		proof.ApplicationSigning, err = b.signAgent(ctx, opts, agent)
		if err != nil {
			return output{}, err
		}
		// Notarization rejects any unsigned executable in the package.
		proof.CLISigning, err = b.signAgent(ctx, opts, srctl)
		if err != nil {
			return output{}, err
		}
	}
	proof.BinarySHA256, err = fileSHA256(agent)
	if err != nil {
		return output{}, err
	}
	proof.CLIBinarySHA256, err = fileSHA256(srctl)
	if err != nil {
		return output{}, err
	}
	pkg, err := b.unsignedPackage(ctx, work, root, scripts, opts.Version)
	if err != nil {
		return output{}, err
	}
	if opts.Mode == modeRelease {
		pkg, err = b.signPackage(ctx, opts, pkg, work, &proof)
		if err != nil {
			return output{}, err
		}
	}
	if err := b.verifyPayload(ctx, pkg, work, in, opts, proof.BinarySHA256, proof.CLIBinarySHA256); err != nil {
		return output{}, err
	}
	proof.PackageSHA256, err = fileSHA256(pkg)
	if err != nil {
		return output{}, err
	}
	if err := exportResult(pkg, out, proof); err != nil {
		return output{}, err
	}
	return out, nil
}

func stage(root, scripts string, in inputs) error {
	files := []struct {
		source, target string
		mode           os.FileMode
	}{
		{in.Agent, filepath.Join(root, agentPayload), 0755},
		{in.Config, filepath.Join(root, configPayload), 0644},
		{in.Plist, filepath.Join(root, plistPayload), 0644},
		{in.Srctl, filepath.Join(root, srctlPayload), 0755},
		{in.Preinstall, filepath.Join(scripts, "preinstall"), 0755},
		{in.Postinstall, filepath.Join(scripts, "postinstall"), 0755},
	}
	for _, f := range files {
		if err := copyFile(f.source, f.target, f.mode); err != nil {
			return err
		}
	}
	return nil
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
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return err
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

func verifyAgent(ctx context.Context, runner commandRunner, path, version string) error {
	m, err := macho.Open(path)
	if err != nil {
		return fmt.Errorf("agent is not a Mach-O executable: %w", err)
	}
	defer func() { _ = m.Close() }()
	if m.Cpu != macho.CpuArm64 || m.Type != macho.TypeExec {
		return fmt.Errorf("%w: agent must be a Darwin ARM64 executable", errInvalidPackage)
	}
	libs, err := m.ImportedLibraries()
	if err != nil {
		return err
	}
	hasIOReport := false
	for _, lib := range libs {
		if filepath.Base(lib) == "libIOReport.dylib" {
			hasIOReport = true
		}
	}
	if !hasIOReport {
		return fmt.Errorf("%w: agent lacks required CGO IOReport telemetry linkage", errInvalidPackage)
	}
	data, err := runner.run(ctx, path, "--version")
	if err != nil {
		return err
	}
	if string(data) != version+"\n" {
		return fmt.Errorf("%w: agent --version does not match the committed FULL_VERSION", errInvalidPackage)
	}
	return nil
}

func (b builder) unsignedPackage(ctx context.Context, work, root, scripts, version string) (string, error) {
	component := filepath.Join(work, "agent-component.pkg")
	if _, err := b.runner.run(ctx, "/usr/bin/pkgbuild", "--root", root, "--scripts", scripts, "--identifier", packageID, "--version", version, "--install-location", "/", "--ownership", "recommended", component); err != nil {
		return "", err
	}
	requirements := filepath.Join(work, "requirements.plist")
	if err := os.WriteFile(requirements, []byte(`<?xml version="1.0"?><plist version="1.0"><dict><key>arch</key><array><string>arm64</string></array></dict></plist>`), 0600); err != nil {
		return "", err
	}
	pkg := filepath.Join(work, "unsigned.pkg")
	_, err := b.runner.run(ctx, "/usr/bin/productbuild", "--package", component, "--product", requirements, "--identifier", packageID, "--version", version, pkg)
	return pkg, err
}

func (b builder) verifyPayload(ctx context.Context, pkg, work string, in inputs, opts options, binarySHA, cliSHA string) error {
	expanded := filepath.Join(work, "expanded")
	if _, err := b.runner.run(ctx, "/usr/sbin/pkgutil", "--expand-full", pkg, expanded); err != nil {
		return err
	}
	component := filepath.Join(expanded, "agent-component.pkg")
	data, err := os.ReadFile(filepath.Join(component, "PackageInfo"))
	if err != nil {
		return err
	}
	var info struct {
		Identifier string `xml:"identifier,attr"`
		Version    string `xml:"version,attr"`
		Location   string `xml:"install-location,attr"`
	}
	if err := xml.Unmarshal(data, &info); err != nil {
		return err
	}
	if info.Identifier != packageID || info.Version != opts.Version || info.Location != "/" {
		return fmt.Errorf("%w: package metadata does not match the release", errInvalidPackage)
	}
	payload := filepath.Join(component, "Payload")
	agent := filepath.Join(payload, agentPayload)
	if err := verifyAgent(ctx, b.runner, agent, opts.Version); err != nil {
		return err
	}
	actualSHA, err := fileSHA256(agent)
	if err != nil {
		return err
	}
	if actualSHA != binarySHA {
		return fmt.Errorf("%w: packaged binary differs from the verified binary", errInvalidPackage)
	}
	srctl := filepath.Join(payload, srctlPayload)
	if err := verifyCLI(srctl); err != nil {
		return err
	}
	actualCLISHA, err := fileSHA256(srctl)
	if err != nil {
		return err
	}
	if actualCLISHA != cliSHA {
		return fmt.Errorf("%w: packaged srctl differs from the verified srctl", errInvalidPackage)
	}
	for _, f := range []struct{ original, packaged string }{
		{in.Config, filepath.Join(payload, configPayload)}, {in.Plist, filepath.Join(payload, plistPayload)},
		{in.Preinstall, filepath.Join(component, "Scripts/preinstall")}, {in.Postinstall, filepath.Join(component, "Scripts/postinstall")},
	} {
		want, err := fileSHA256(f.original)
		if err != nil {
			return err
		}
		got, err := fileSHA256(f.packaged)
		if err != nil {
			return err
		}
		if got != want {
			return fmt.Errorf("%w: packaged configuration or install hook differs from its declared input", errInvalidPackage)
		}
	}
	if opts.Mode == modeRelease {
		if _, err = b.verifyAgentSignature(ctx, agent, opts.AppIdentity); err != nil {
			return err
		}
		_, err = b.verifyAgentSignature(ctx, srctl, opts.AppIdentity)
	}
	return err
}

// verifyCLI checks that srctl is a Darwin ARM64 executable. It is not run:
// with no subcommand it reads a password to hash.
func verifyCLI(path string) error {
	m, err := macho.Open(path)
	if err != nil {
		return fmt.Errorf("srctl is not a Mach-O executable: %w", err)
	}
	defer func() { _ = m.Close() }()
	if m.Cpu != macho.CpuArm64 || m.Type != macho.TypeExec {
		return fmt.Errorf("%w: srctl must be a Darwin ARM64 executable", errInvalidPackage)
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

func exportResult(pkg string, out output, proof provenance) error {
	data, err := json.MarshalIndent(proof, "", "  ")
	if err != nil {
		return err
	}
	stagedProof := filepath.Join(filepath.Dir(pkg), "provenance.json")
	if err := os.WriteFile(stagedProof, append(data, '\n'), 0644); err != nil {
		return err
	}
	if err := os.Chmod(pkg, 0644); err != nil {
		return err
	}
	// Staging lives on the output filesystem. Hard links publish complete bytes
	// atomically and refuse to replace another invocation's existing output.
	if err := os.Link(pkg, out.PackagePath); err != nil {
		return err
	}
	if err := os.Link(stagedProof, out.ProvenancePath); err != nil {
		_ = os.Remove(out.PackagePath)
		return err
	}
	return nil
}
