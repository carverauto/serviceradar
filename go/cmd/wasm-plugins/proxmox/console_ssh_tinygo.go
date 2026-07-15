//go:build tinygo

package main

import (
	"encoding/json"
	"errors"
)

func streamSSHConsole(
	cfg consoleConfig,
	bridge proxmoxConsoleBridge,
	_ func(consoleConfig) (sshConsoleSession, error),
) error {
	// The host already retains the immutable session target and broker grant.
	// Never echo config, credentials, destination, or host-key policy back across
	// the untrusted Wasm ABI.
	payload, err := json.Marshal(struct {
		SessionID string `json:"session_id"`
	}{SessionID: cfg.Console.SessionID})
	if err != nil {
		return err
	}
	if code := hostProxmoxConsoleSSHConnect(ptrFromBytes(payload), uint32(len(payload))); code < 0 {
		_ = bridge.Write([]byte("Unable to open SSH console via agent host connector.\r\n"))
		return errConsoleConnectorUnsupported
	}
	return nil
}

func dialSSHConsole(_ consoleConfig) (sshConsoleSession, error) {
	return nil, errors.New("SSH console transport is unavailable in TinyGo/Wasm")
}
