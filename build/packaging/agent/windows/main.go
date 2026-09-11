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

var fullVersion string

func main() {
	if err := runCLI(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runCLI(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("%w: usage: package stage|build [flags]", errInvalidPackage)
	}

	switch args[0] {
	case "stage":
		return runStage(args[1:])
	case "build":
		return runBuild(args[1:])
	default:
		return fmt.Errorf("%w: unknown subcommand %q (want stage or build)", errInvalidPackage, args[0])
	}
}

// runStage copies the declared MSI inputs out of runfiles for the Windows job.
func runStage(args []string) error {
	fs := flag.NewFlagSet("stage", flag.ContinueOnError)
	outputDir := fs.String("output-dir", "", "absolute, existing, empty directory outside the Bazel output tree")
	sourceCommit := fs.String("source-commit", "", "full source commit being packaged")
	if err := fs.Parse(args); err != nil {
		return err
	}

	in, err := declaredInputs()
	if err != nil {
		return err
	}

	if err := stage(*outputDir, fullVersion, *sourceCommit, in); err != nil {
		return err
	}

	fmt.Printf("staged Windows installer inputs for %s in %s\n", fullVersion, *outputDir)

	return nil
}

// runBuild runs on the Windows runner: it builds and verifies both MSIs.
func runBuild(args []string) error {
	fs := flag.NewFlagSet("build", flag.ContinueOnError)
	var opts buildOptions
	fs.StringVar(&opts.InputDir, "input-dir", "", "directory written by the stage subcommand")
	fs.StringVar(&opts.OutputDir, "output-dir", "", "absolute, existing directory for the MSIs and provenance")
	fs.StringVar(&opts.SourceCommit, "source-commit", "", "full source commit the inputs were staged from")
	fs.StringVar(&opts.Wix, "wix", "wix", "WiX Toolset v5 command")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if runtime.GOOS != "windows" {
		return fmt.Errorf("%w: building the MSI requires a Windows host (WiX and msiexec)", errInvalidPackage)
	}

	opts.Version = fullVersion

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	outs, err := (builder{runner: systemRunner{}, hostArch: runtime.GOARCH}).build(ctx, opts)
	if err != nil {
		return err
	}

	for _, out := range outs {
		fmt.Printf("package: %s\nprovenance: %s\n", out.MSIPath, out.ProvenancePath)
	}

	return nil
}

func declaredInputs() (stageInputs, error) {
	var in stageInputs

	for key, target := range map[string]*string{
		"SERVICERADAR_WINDOWS_AGENT_AMD64_RUNFILE": &in.AgentAMD64,
		"SERVICERADAR_WINDOWS_AGENT_ARM64_RUNFILE": &in.AgentARM64,
		"SERVICERADAR_WINDOWS_CONFIG_RUNFILE":      &in.Config,
		"SERVICERADAR_WINDOWS_PACKAGER_RUNFILE":    &in.Packager,
	} {
		logical := os.Getenv(key)
		if logical == "" {
			return stageInputs{}, fmt.Errorf("%w: %s is unset; run this through bazel run", errInvalidPackage, key)
		}

		path, err := runfiles.Rlocation(logical)
		if err != nil {
			return stageInputs{}, fmt.Errorf("resolve %s: %w", key, err)
		}

		*target = path
	}

	return in, nil
}
