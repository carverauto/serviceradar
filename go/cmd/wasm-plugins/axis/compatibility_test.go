package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestAxisPluginBuildsWithTinyGo(t *testing.T) {
	tinygo, err := exec.LookPath("tinygo")
	if err != nil {
		t.Skip("tinygo not installed")
	}

	output := filepath.Join(t.TempDir(), "axis-plugin.wasm")
	cmd := exec.Command(
		tinygo,
		"build",
		"-target=wasi",
		"-gc=leaking",
		"-scheduler=none",
		"-no-debug",
		"-o",
		output,
		"./",
	)

	cmd.Dir = "."
	cmd.Env = append(os.Environ(), "GOTOOLCHAIN=go1.25.4")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("tinygo build failed: %v\n%s", err, out)
	}
}
