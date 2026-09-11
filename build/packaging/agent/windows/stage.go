package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type stageInputs struct{ AgentAMD64, AgentARM64, SrctlAMD64, SrctlARM64, Config, Packager string }

// stage copies the MSI inputs into outputDir with an inputs.json recording
// their digests, for the Windows job that runs the packager.
func stage(outputDir, version, commit string, in stageInputs) error {
	if err := validateRelease(version, commit); err != nil {
		return err
	}

	if err := validateOutputDir(outputDir); err != nil {
		return err
	}

	manifest := stagedInputs{SchemaVersion: 1, Version: version, SourceCommit: commit, Files: map[string]string{}}

	for name, source := range map[string]string{
		agentInputName("amd64"): in.AgentAMD64,
		agentInputName("arm64"): in.AgentARM64,
		srctlInputName("amd64"): in.SrctlAMD64,
		srctlInputName("arm64"): in.SrctlARM64,
		configFileName:          in.Config,
		packagerFileName:        in.Packager,
	} {
		target := filepath.Join(outputDir, name)
		if err := copyFile(source, target, 0o755); err != nil {
			return fmt.Errorf("stage %s: %w", name, err)
		}

		sum, err := fileSHA256(target)
		if err != nil {
			return err
		}

		manifest.Files[name] = sum
	}

	for _, arch := range architectures {
		if err := verifyPE(filepath.Join(outputDir, agentInputName(arch)), arch); err != nil {
			return err
		}

		if err := verifyPE(filepath.Join(outputDir, srctlInputName(arch)), arch); err != nil {
			return fmt.Errorf("srctl: %w", err)
		}
	}

	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.OpenFile(filepath.Join(outputDir, inputsFileName), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}

	_, writeErr := f.Write(append(data, '\n'))
	closeErr := f.Close()

	if writeErr != nil {
		return writeErr
	}

	return closeErr
}
