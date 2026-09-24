//go:build !tinygo

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// localArtifactDirVariable enables artifact staging for local runs, which
// config.retrieve needs. Artifacts can contain device secrets; keep the
// directory outside the repository.
const localArtifactDirVariable = "SERVICERADAR_LOCAL_ARTIFACT_DIR"

func main() {
	if err := runLocalMain(); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runLocalMain() error {
	inputs, err := sdk.LoadLocalInputs(sdk.LocalInputOptions{})
	if err != nil {
		return fmt.Errorf("local input error: %w", err)
	}
	runtimeConfig, err := inputs.RuntimeConfigJSON()
	if err != nil {
		return fmt.Errorf("local input error: %w", err)
	}
	cfg, err := parseLocalRuntimeConfig(runtimeConfig)
	if err != nil {
		// Runtime config holds no credentials, so the parse error is safe to
		// show; the bare code alone hid which field was rejected.
		return fmt.Errorf("local config error: %s: %v", safeErrorCode(err), err)
	}

	broker, err := newLocalOAuthBroker(cfg, inputs.Credentials(), nil)
	if err != nil {
		return err
	}
	capture, runErr := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON:  runtimeConfig,
		HTTPHandler: broker.Handle,
		ArtifactDir: strings.TrimSpace(os.Getenv(localArtifactDirVariable)),
	}, runPlugin)
	for _, artifact := range capture.Artifacts {
		_, _ = fmt.Fprintf(os.Stderr, "artifact %s -> %s (%d bytes, sha256 %s)\n",
			artifact.ObjectKey, artifact.Path, artifact.SizeBytes, artifact.SHA256)
	}
	if runErr != nil {
		return fmt.Errorf("local plugin execution failed: %w", runErr)
	}
	if len(capture.ResultJSON) == 0 {
		return errors.New("local plugin execution submitted no result")
	}
	if brokerErr := broker.SafeError(); brokerErr != "" {
		return fmt.Errorf("local host request failed: %s", brokerErr)
	}

	var result struct {
		Status  string `json:"status"`
		Summary string `json:"summary"`
	}
	if err := json.Unmarshal(capture.ResultJSON, &result); err != nil {
		return errors.New("local plugin execution submitted an invalid result")
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, capture.ResultJSON, "", "  "); err != nil {
		return errors.New("local plugin result could not be formatted")
	}
	pretty.WriteByte('\n')
	if _, err := pretty.WriteTo(os.Stdout); err != nil {
		return fmt.Errorf("write local plugin result: %w", err)
	}
	if result.Status == "CRITICAL" {
		return fmt.Errorf("local plugin result is critical: %s", result.Summary)
	}
	return nil
}

func parseLocalRuntimeConfig(runtimeConfig []byte) (Config, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(runtimeConfig, &raw); err != nil {
		return Config{}, err
	}
	if err := json.Unmarshal(runtimeConfig, &raw); err != nil {
		return Config{}, err
	}
	payload, err := runtimeConfigPayload(raw)
	if err != nil {
		return Config{}, err
	}
	return ParseConfig(payload)
}
