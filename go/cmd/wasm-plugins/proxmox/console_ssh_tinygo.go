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
	payload, err := json.Marshal(cfg)
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
