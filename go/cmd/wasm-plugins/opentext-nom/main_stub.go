//go:build !tinygo

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

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
		return fmt.Errorf("local config error: %s", safeErrorCode(err))
	}

	broker, err := newLocalOAuthBroker(cfg, inputs.Credentials(), nil)
	if err != nil {
		return err
	}
	capture, runErr := sdk.RunLocalHost(sdk.LocalHostOptions{
		ConfigJSON:  runtimeConfig,
		HTTPHandler: broker.Handle,
	}, runPlugin)
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
	payload, err := runtimeConfigPayload(raw)
	if err != nil {
		return Config{}, err
	}
	return ParseConfig(payload)
}
