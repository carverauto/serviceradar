package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

//nolint:gochecknoglobals // Bazel binds the committed VERSION to this executable.
var fullVersion string

func main() {
	if err := runCLI(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runCLI() error {
	var opts options
	flag.StringVar(&opts.Mode, "mode", "", "required: unsigned (local testing) or release (signed and notarized)")
	flag.StringVar(&opts.OutputDir, "output-dir", "", "absolute output directory outside the Bazel output tree")
	flag.StringVar(&opts.SourceCommit, "source-commit", "", "full source commit verified by the invoking workflow")
	flag.StringVar(&opts.Keychain, "keychain", "", "isolated signing and notarization keychain (release only)")
	flag.StringVar(&opts.NotaryProfile, "notary-profile", "", "notarytool profile stored in the specified keychain (release only)")
	flag.Parse()
	if flag.NArg() != 0 {
		return fmt.Errorf("%w: unexpected positional arguments", errInvalidPackage)
	}
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		return fmt.Errorf("%w: macOS packaging requires a Darwin ARM64 host", errInvalidPackage)
	}
	opts.Version = fullVersion
	opts.AppIdentity = os.Getenv("PKG_APP_SIGN_IDENTITY")
	opts.InstallerIdentity = os.Getenv("PKG_SIGN_IDENTITY")
	if err := opts.validate(); err != nil {
		return err
	}
	in, err := declaredInputs()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	defer cancel()
	result, err := (builder{runner: systemRunner{env: platformEnvironment()}}).build(ctx, opts, in)
	if err != nil {
		return err
	}
	fmt.Printf("%s package: %s\nprovenance: %s\n", opts.Mode, result.PackagePath, result.ProvenancePath)
	return nil
}

func declaredInputs() (inputs, error) {
	var in inputs
	for key, target := range map[string]*string{
		"SERVICERADAR_MACOS_AGENT_RUNFILE":       &in.Agent,
		"SERVICERADAR_MACOS_CONFIG_RUNFILE":      &in.Config,
		"SERVICERADAR_MACOS_PLIST_RUNFILE":       &in.Plist,
		"SERVICERADAR_MACOS_PREINSTALL_RUNFILE":  &in.Preinstall,
		"SERVICERADAR_MACOS_POSTINSTALL_RUNFILE": &in.Postinstall,
	} {
		logical := os.Getenv(key)
		if logical == "" {
			return in, fmt.Errorf("%w: missing declared input %s; invoke the Bazel package target", errInvalidPackage, key)
		}
		resolved, err := runfiles.Rlocation(logical)
		if err != nil {
			return in, fmt.Errorf("resolve declared input %s: %w", key, err)
		}
		*target = resolved
	}
	return in, nil
}
