package main

import (
	"bytes"
	"context"
	"debug/macho"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

var errSyntheticPlatform = errors.New("synthetic platform failure")

const testVersion = "2.3.4"
const testAppIdentity = "Developer ID Application: Synthetic Software (TESTTEAM01)"
const testInstallerIdentity = "Developer ID Installer: Synthetic Software (TESTTEAM01)"

type fakeTools struct {
	t             *testing.T
	fail          string
	mutate        string
	version       string
	root, scripts string
	calls         []string
}

func (f *fakeTools) run(_ context.Context, name string, args ...string) ([]byte, error) {
	tool := filepath.Base(name)
	step := tool
	if len(args) > 0 {
		step += " " + args[0]
	}
	if tool == "xcrun" && len(args) > 1 && args[0] == "stapler" {
		step += " " + args[1]
	}
	f.calls = append(f.calls, step)
	if f.fail == step {
		return nil, errSyntheticPlatform
	}
	switch tool {
	case "serviceradar-agent":
		if f.mutate == "version" {
			return []byte("0.0.0\n"), nil
		}
		return []byte(f.packageVersion() + "\n"), nil
	case "pkgbuild":
		f.root, f.scripts = flagValue(args, "--root"), flagValue(args, "--scripts")
		writeTestFile(f.t, args[len(args)-1], []byte("synthetic component"))
	case "productbuild":
		data, err := os.ReadFile(flagValue(args, "--product"))
		if err != nil {
			return nil, err
		}
		if !bytes.Contains(data, []byte("<string>arm64</string>")) {
			return nil, fmt.Errorf("%w: missing ARM64 installer requirement", errSyntheticPlatform)
		}
		writeTestFile(f.t, args[len(args)-1], []byte("synthetic unsigned installer"))
	case "codesign":
		if args[0] == "--display" {
			return f.applicationSignatureOutput(), nil
		}
	case "productsign":
		writeTestFile(f.t, args[len(args)-1], []byte("synthetic signed installer"))
	case "pkgutil":
		if args[0] == "--check-signature" {
			status := "signed by a developer certificate issued by Apple for distribution"
			if f.mutate == "legacy-status" {
				status = "signed by a certificate trusted by macOS"
			}
			if f.mutate == "untrusted-status" {
				status = "signed by an untrusted certificate"
			}
			identity, timestamp := testInstallerIdentity, "Signed with a trusted timestamp on: 2001-01-01 00:00:00 +0000\n"
			if f.mutate == "installer-identity" {
				identity = "Developer ID Installer: Other Software (OTHERTEM01)"
			}
			if f.mutate == "installer-timestamp" {
				timestamp = ""
			}
			return []byte("Status: " + status + "\n" + timestamp + "Certificate Chain:\n  1. " + identity + "\n"), nil
		}
		if args[0] == "--expand-full" {
			return nil, f.expand(args[2])
		}
	case "xcrun":
		if args[0] == "notarytool" {
			if f.mutate == "notary-invalid" {
				return []byte(`{"id":"11111111-2222-4333-8444-555555555555","status":"Invalid"}`), nil
			}
			if f.mutate == "notary-json" {
				return []byte("not JSON"), nil
			}
			return []byte(`{"id":"11111111-2222-4333-8444-555555555555","status":"Accepted"}`), nil
		}
	case "spctl":
		if f.mutate == "gatekeeper" {
			return []byte("package.pkg: rejected\n"), nil
		}
		return []byte("package.pkg: accepted\nsource=Notarized Developer ID\n"), nil
	default:
		return nil, fmt.Errorf("%w: unexpected command %s", errSyntheticPlatform, tool)
	}
	return nil, nil
}

func (f *fakeTools) applicationSignatureOutput() []byte {
	identity, flags, timestamp := testAppIdentity, "10000", "Timestamp=Jan 1, 2001 at 12:00:00 AM\n"
	if f.mutate == "app-identity" {
		identity = "Developer ID Application: Other Software (OTHERTEM01)"
	}
	if f.mutate == "runtime" {
		flags = "0"
	}
	if f.mutate == "adhoc" {
		flags = "10002"
	}
	if f.mutate == "app-timestamp" {
		timestamp = ""
	}
	return []byte("CodeDirectory v=20500 size=42 flags=0x" + flags + "(runtime) hashes=1+7 location=embedded\nAuthority=" + identity + "\nTeamIdentifier=TESTTEAM01\n" + timestamp)
}

func (f *fakeTools) packageVersion() string {
	if f.version != "" {
		return f.version
	}
	return testVersion
}

func flagValue(args []string, flag string) string {
	for i, arg := range args {
		if arg == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func (f *fakeTools) expand(dir string) error {
	component := filepath.Join(dir, "agent-component.pkg")
	for source, target := range map[string]string{f.root: filepath.Join(component, "Payload"), f.scripts: filepath.Join(component, "Scripts")} {
		err := filepath.WalkDir(source, func(path string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if d.IsDir() {
				return nil
			}
			rel, err := filepath.Rel(source, path)
			if err != nil {
				return err
			}
			return copyFile(path, filepath.Join(target, rel), 0755)
		})
		if err != nil {
			return err
		}
	}
	version := f.packageVersion()
	if f.mutate == "package-version" {
		version = "9.9.9"
	}
	writeTestFile(f.t, filepath.Join(component, "PackageInfo"), []byte(`<pkg-info identifier="com.serviceradar.agent" version="`+version+`" install-location="/"/>`))
	if f.mutate == "payload-config" {
		writeTestFile(f.t, filepath.Join(component, "Payload", configPayload), []byte(`{"changed":true}`))
	}
	if f.mutate == "payload-srctl" {
		writeTestFile(f.t, filepath.Join(component, "Payload", srctlPayload), fakeMachO(f.t, macho.CpuArm64, true))
	}
	return nil
}

func writeTestFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0755); err != nil {
		t.Fatal(err)
	}
}

func fakeMachO(t *testing.T, cpu macho.Cpu, ioReport bool) []byte {
	t.Helper()
	lib := "/usr/lib/libIOReport.dylib"
	if !ioReport {
		lib = "/usr/lib/libSystem.B.dylib"
	}
	cmdSize := (24 + len(lib) + 1 + 7) &^ 7
	var b bytes.Buffer
	words := []uint32{macho.Magic64, uint32(cpu), 0, uint32(macho.TypeExec), 1, uint32(cmdSize), 0, 0, 0xc, uint32(cmdSize), 24, 0, 0, 0}
	for _, v := range words {
		if err := binary.Write(&b, binary.LittleEndian, v); err != nil {
			t.Fatal(err)
		}
	}
	b.WriteString(lib)
	b.Write(make([]byte, cmdSize-24-len(lib)))
	return b.Bytes()
}

func fixtures(t *testing.T, mode string) (options, inputs) {
	t.Helper()
	dir := t.TempDir()
	source := filepath.Join(dir, "inputs")
	out := filepath.Join(dir, "output")
	if err := os.Mkdir(out, 0700); err != nil {
		t.Fatal(err)
	}
	in := inputs{filepath.Join(source, "agent"), filepath.Join(source, "config"), filepath.Join(source, "plist"), filepath.Join(source, "preinstall"), filepath.Join(source, "postinstall"), filepath.Join(source, "srctl")}
	writeTestFile(t, in.Agent, fakeMachO(t, macho.CpuArm64, true))
	writeTestFile(t, in.Srctl, fakeMachO(t, macho.CpuArm64, false))
	for _, p := range []string{in.Config, in.Plist, in.Preinstall, in.Postinstall} {
		writeTestFile(t, p, []byte("synthetic installer input\n"))
	}
	keychain := filepath.Join(dir, "synthetic.keychain-db")
	writeTestFile(t, keychain, []byte("synthetic test keychain"))
	return options{Mode: mode, OutputDir: out, Version: testVersion, SourceCommit: strings.Repeat("1", 40), Keychain: keychain, NotaryProfile: "synthetic-profile", AppIdentity: testAppIdentity, InstallerIdentity: testInstallerIdentity}, in
}

func TestUnsignedPackageIsExplicitlyNonRelease(t *testing.T) {
	opts, in := fixtures(t, modeUnsigned)
	opts.AppIdentity = ""
	opts.InstallerIdentity = ""
	opts.Keychain = ""
	opts.NotaryProfile = ""
	tools := &fakeTools{t: t}
	out, err := (builder{runner: tools}).build(t.Context(), opts, in)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(out.PackagePath) != "serviceradar-agent_2.3.4_darwin_arm64.unsigned.pkg" {
		t.Fatal(out)
	}
	var proof provenance
	data, err := os.ReadFile(out.ProvenancePath)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &proof); err != nil {
		t.Fatal(err)
	}
	if proof.Mode != modeUnsigned || proof.ApplicationSigning.Verified || proof.InstallerSigning.Verified || proof.GatekeeperVerified {
		t.Fatal("unsigned output claimed release verification")
	}
	for _, call := range tools.calls {
		if strings.HasPrefix(call, "codesign ") || strings.HasPrefix(call, "productsign ") || strings.HasPrefix(call, "xcrun ") || strings.HasPrefix(call, "spctl ") {
			t.Fatal("unsigned mode contacted signing tools")
		}
	}
}

func TestReleaseExportRequiresCompleteVerification(t *testing.T) {
	opts, in := fixtures(t, modeRelease)
	tools := &fakeTools{t: t}
	out, err := (builder{runner: tools}).build(t.Context(), opts, in)
	if err != nil {
		t.Fatal(err)
	}
	var proof provenance
	data, err := os.ReadFile(out.ProvenancePath)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &proof); err != nil {
		t.Fatal(err)
	}
	if proof.Mode != modeRelease || !proof.ApplicationSigning.Verified || !proof.ApplicationSigning.HardenedRuntime || !proof.InstallerSigning.Verified || proof.Notarization.Status != "Accepted" || !proof.Notarization.Stapled || !proof.Notarization.Validated || !proof.GatekeeperVerified {
		t.Fatalf("incomplete proof: %+v", proof)
	}
	digest, err := fileSHA256(out.PackagePath)
	if err != nil {
		t.Fatal(err)
	}
	if proof.PackageSHA256 != digest {
		t.Fatal("package hash mismatch")
	}
	if proof.SourceCommit != opts.SourceCommit || proof.Version != opts.Version || proof.PackageFilename != filepath.Base(out.PackagePath) {
		t.Fatal("source/version binding mismatch")
	}
	want := []string{
		"serviceradar-agent --version",
		"codesign --force", "codesign --verify", "codesign --display", // agent
		"codesign --force", "codesign --verify", "codesign --display", // srctl
		"pkgbuild --root", "productbuild --package", "productsign --sign", "pkgutil --check-signature", "xcrun notarytool", "xcrun stapler staple", "xcrun stapler validate", "pkgutil --check-signature", "spctl --assess", "pkgutil --expand-full",
		"serviceradar-agent --version",
		"codesign --verify", "codesign --display", // packaged agent
		"codesign --verify", "codesign --display", // packaged srctl
	}
	if !reflect.DeepEqual(tools.calls, want) {
		t.Fatalf("unexpected verification order: %v", tools.calls)
	}
}

func TestReleaseFailsClosedWithoutExport(t *testing.T) {
	cases := []struct{ name, fail, mutate string }{
		{"codesign fails", "codesign --force", ""}, {"binary verification fails", "codesign --verify", ""}, {"package build fails", "pkgbuild --root", ""}, {"product signing fails", "productsign --sign", ""}, {"notarytool fails", "xcrun notarytool", ""}, {"stapling fails", "xcrun stapler staple", ""}, {"staple validation fails", "xcrun stapler validate", ""}, {"signature validation fails", "pkgutil --check-signature", ""}, {"Gatekeeper fails", "spctl --assess", ""},
		{"wrong embedded version", "", "version"}, {"wrong app signer", "", "app-identity"}, {"runtime missing", "", "runtime"}, {"ad hoc signature", "", "adhoc"}, {"app timestamp missing", "", "app-timestamp"}, {"untrusted installer", "", "untrusted-status"}, {"wrong installer signer", "", "installer-identity"}, {"installer timestamp missing", "", "installer-timestamp"}, {"notary rejected", "", "notary-invalid"}, {"notary malformed", "", "notary-json"}, {"Gatekeeper rejected", "", "gatekeeper"}, {"package metadata wrong", "", "package-version"}, {"payload changed", "", "payload-config"}, {"packaged srctl changed", "", "payload-srctl"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			opts, in := fixtures(t, modeRelease)
			tools := &fakeTools{t: t, fail: tc.fail, mutate: tc.mutate}
			if _, err := (builder{runner: tools}).build(t.Context(), opts, in); err == nil {
				t.Fatal("invalid release accepted")
			}
			entries, err := os.ReadDir(opts.OutputDir)
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) != 0 {
				t.Fatalf("failure exported files: %v", entries)
			}
		})
	}
}

func TestMissingReleaseCredentialsFailBeforePlatformCommands(t *testing.T) {
	for _, name := range []string{"application", "installer", "keychain", "profile", "team"} {
		t.Run(name, func(t *testing.T) {
			opts, in := fixtures(t, modeRelease)
			switch name {
			case "application":
				opts.AppIdentity = ""
			case "installer":
				opts.InstallerIdentity = ""
			case "keychain":
				opts.Keychain = ""
			case "profile":
				opts.NotaryProfile = ""
			case "team":
				opts.InstallerIdentity = "Developer ID Installer: Other Software (OTHERTEM01)"
			}
			tools := &fakeTools{t: t}
			if _, err := (builder{runner: tools}).build(t.Context(), opts, in); err == nil {
				t.Fatal("missing credentials accepted")
			}
			if len(tools.calls) != 0 {
				t.Fatal("invoked tools before validating credentials")
			}
		})
	}
}

func TestAgentRequiresARM64CGO(t *testing.T) {
	for _, tc := range []struct {
		name     string
		cpu      macho.Cpu
		ioReport bool
	}{{"wrong architecture", macho.CpuAmd64, true}, {"pure Go", macho.CpuArm64, false}} {
		t.Run(tc.name, func(t *testing.T) {
			opts, in := fixtures(t, modeUnsigned)
			writeTestFile(t, in.Agent, fakeMachO(t, tc.cpu, tc.ioReport))
			if _, err := (builder{runner: &fakeTools{t: t}}).build(t.Context(), opts, in); err == nil {
				t.Fatal("invalid agent accepted")
			}
		})
	}
}

func TestExistingPackageIsNeverReplaced(t *testing.T) {
	opts, in := fixtures(t, modeRelease)
	path := filepath.Join(opts.OutputDir, "serviceradar-agent_2.3.4_darwin_arm64.pkg")
	original := []byte("previous synthetic artifact")
	writeTestFile(t, path, original)
	if _, err := (builder{runner: &fakeTools{t: t}}).build(t.Context(), opts, in); err == nil {
		t.Fatal("existing artifact replaced")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, original) {
		t.Fatal("existing artifact changed")
	}
}

func TestPlatformEnvironmentDoesNotCarrySecrets(t *testing.T) {
	t.Setenv("PKG_APP_SIGN_IDENTITY", "synthetic identity")
	t.Setenv("PKG_SIGN_IDENTITY", "synthetic installer identity")
	t.Setenv("APPLE_API_PRIVATE_KEY", "synthetic sensitive fixture")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "synthetic sensitive fixture")
	for _, entry := range platformEnvironment() {
		if strings.Contains(entry, "synthetic") {
			t.Fatal("secret or signing identity leaked into platform subprocess environment")
		}
	}
}

func TestSupportedPrereleasesRetainExactVersion(t *testing.T) {
	for _, version := range []string{"2.3.4-pre1", "2.3.4-rc2", "2.3.4-alpha0", "2.3.4-beta3"} {
		t.Run(version, func(t *testing.T) {
			opts, in := fixtures(t, modeRelease)
			opts.Version = version
			out, err := (builder{runner: &fakeTools{t: t, version: version}}).build(t.Context(), opts, in)
			if err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(out.ProvenancePath)
			if err != nil {
				t.Fatal(err)
			}
			var proof provenance
			if err := json.Unmarshal(data, &proof); err != nil {
				t.Fatal(err)
			}
			if proof.Version != version || filepath.Base(out.PackagePath) != "serviceradar-agent_"+version+"_darwin_arm64.pkg" {
				t.Fatal("prerelease identity was changed")
			}
		})
	}
}

func TestLegacyTrustedInstallerStatusRemainsSupported(t *testing.T) {
	opts, in := fixtures(t, modeRelease)
	if _, err := (builder{runner: &fakeTools{t: t, mutate: "legacy-status"}}).build(t.Context(), opts, in); err != nil {
		t.Fatal(err)
	}
}

func TestPlatformFailureDoesNotExposeOutputOrArguments(t *testing.T) {
	const marker = "synthetic-private-platform-text"
	if os.Getenv("SERVICERADAR_PACKAGE_TEST_FAILURE") == "1" {
		_, _ = fmt.Fprintln(os.Stdout, marker)
		fmt.Fprintln(os.Stderr, marker)
		os.Exit(23)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	runner := systemRunner{env: append(platformEnvironment(), "SERVICERADAR_PACKAGE_TEST_FAILURE=1")}
	data, err := runner.run(t.Context(), executable, "-test.run=^TestPlatformFailureDoesNotExposeOutputOrArguments$", "--", marker)
	if err == nil || !strings.Contains(err.Error(), "exit status 23") {
		t.Fatalf("expected explicit failure, got %v", err)
	}
	if len(data) != 0 || strings.Contains(err.Error(), marker) {
		t.Fatal("platform output or arguments escaped failure redaction")
	}
}

// A signing failure has to say why, or a release that stops at codesign cannot be
// diagnosed from its (public) log: all it said was "codesign failed: exit status 1".
// The cause comes from a fixed vocabulary; the output itself still never escapes,
// because it names the identity and the keychain.
func TestPlatformFailureNamesAKnownCauseWithoutItsOutput(t *testing.T) {
	if os.Getenv("SERVICERADAR_PACKAGE_TEST_KNOWN_FAILURE") == "1" {
		fmt.Fprintf(os.Stderr, "%s: no identity found\n", testAppIdentity)
		os.Exit(1)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	runner := systemRunner{env: append(platformEnvironment(), "SERVICERADAR_PACKAGE_TEST_KNOWN_FAILURE=1")}
	_, err = runner.run(t.Context(), executable, "-test.run=^TestPlatformFailureNamesAKnownCauseWithoutItsOutput$")
	if err == nil || !strings.Contains(err.Error(), "signing identity not found") {
		t.Fatalf("expected the failure to name its cause, got %v", err)
	}
	if strings.Contains(err.Error(), testAppIdentity) || strings.Contains(err.Error(), "TESTTEAM01") {
		t.Fatal("platform output escaped failure redaction")
	}
}

// A command that never returns -- codesign waiting on a keychain prompt -- must fail
// within its bound and name the tool, instead of leaving the release log silent.
func TestPlatformCommandThatHangsFailsWithItsName(t *testing.T) {
	if os.Getenv("SERVICERADAR_PACKAGE_TEST_HANG") == "1" {
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	runner := systemRunner{env: append(platformEnvironment(), "SERVICERADAR_PACKAGE_TEST_HANG=1"), limit: 300 * time.Millisecond}
	started := time.Now()
	_, err = runner.run(t.Context(), executable, "-test.run=^TestPlatformCommandThatHangsFailsWithItsName$")
	if err == nil || !strings.Contains(err.Error(), "timed out after 300ms") || !strings.Contains(err.Error(), filepath.Base(executable)) {
		t.Fatalf("expected a named timeout, got %v", err)
	}
	if elapsed := time.Since(started); elapsed > 20*time.Second {
		t.Fatalf("the hung command held the packager for %s", elapsed)
	}
}

func TestCommandStepNamesToolAndSubcommandOnly(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"/usr/bin/xcrun", []string{"notarytool", "submit", "/tmp/pkg"}, "xcrun notarytool"},
		{"/usr/bin/codesign", []string{"--force", "--sign", testAppIdentity}, "codesign --force"},
		{"/tmp/root/serviceradar-agent", []string{"--version"}, "serviceradar-agent --version"},
		{"/usr/bin/pkgbuild", []string{"/tmp/root"}, "pkgbuild"},
		{"/usr/bin/tool", []string{"--keychain=/tmp/release.keychain-db"}, "tool"},
	}
	for _, c := range cases {
		if got := commandStep(c.name, c.args); got != c.want {
			t.Errorf("commandStep(%q, %q) = %q, want %q", c.name, c.args, got, c.want)
		}
	}
}

func TestNotarytoolGetsALongerBoundThanOtherCommands(t *testing.T) {
	if commandTimeout("/usr/bin/xcrun", []string{"notarytool", "submit"}) <= commandTimeout("/usr/bin/codesign", []string{"--force"}) {
		t.Fatal("notarytool must be allowed its own --timeout")
	}
}

func TestSigningFailureReasonUsesAFixedVocabulary(t *testing.T) {
	cases := []struct{ name, output, want string }{
		{"identity not in keychain", "error: The specified item could not be found in the keychain.", "signing identity not found"},
		{"identity absent", testAppIdentity + ": no identity found", "signing identity not found"},
		{"installer identity absent", `productsign: error: Could not find appropriate signing identity for "` + testInstallerIdentity + `".`, "signing identity not found"},
		{"ambiguous identity", testAppIdentity + `: ambiguous (matches "A" and "B" in /tmp/release.keychain-db)`, "more than one certificate"},
		{"key access denied", testAppIdentity + ": errSecInternalComponent", "keychain denied access"},
		{"incomplete chain", `Warning: unable to build chain to self-signed root for signer "` + testAppIdentity + `"`, "certificate chain is incomplete"},
		{"timestamp unavailable", "The timestamp service is not available.", "timestamp service"},
		{"extended attributes", "resource fork, Finder information, or similar detritus not allowed", "extended attributes"},
		{"unknown", "something else entirely", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := signingFailureReason([]byte(tc.output))
			if tc.want == "" {
				if got != "" {
					t.Fatalf("unrecognised output produced a reason: %q", got)
				}
				return
			}
			if !strings.Contains(got, tc.want) {
				t.Fatalf("got %q, want it to mention %q", got, tc.want)
			}
			if strings.Contains(got, "TESTTEAM01") || strings.Contains(got, "keychain-db") {
				t.Fatalf("reason %q carries platform output", got)
			}
		})
	}
}

func TestPackageShipsSigningCheckedSrctl(t *testing.T) {
	opts, in := fixtures(t, modeRelease)
	tools := &fakeTools{t: t}
	out, err := (builder{runner: tools}).build(t.Context(), opts, in)
	if err != nil {
		t.Fatal(err)
	}
	var proof provenance
	data, err := os.ReadFile(out.ProvenancePath)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &proof); err != nil {
		t.Fatal(err)
	}
	if !proof.CLISigning.Verified || !proof.CLISigning.HardenedRuntime || proof.CLIBinarySHA256 == "" {
		t.Fatalf("srctl was not signed and recorded: %+v", proof.CLISigning)
	}
	// verifyPayload already requires the packaged srctl to match the signed one;
	// here, both executables must have been signed.
	signed := 0
	for _, call := range tools.calls {
		if call == "codesign --force" {
			signed++
		}
	}
	if signed != 2 {
		t.Fatalf("codesign --force ran %d times, want 2 (agent and srctl)", signed)
	}
}

func TestSrctlMustBeADarwinARM64Executable(t *testing.T) {
	opts, in := fixtures(t, modeUnsigned)
	writeTestFile(t, in.Srctl, fakeMachO(t, macho.CpuAmd64, false))
	if _, err := (builder{runner: &fakeTools{t: t}}).build(t.Context(), opts, in); err == nil {
		t.Fatal("an x86-64 srctl was packaged")
	}
}
