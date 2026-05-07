package main

import (
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unsafe"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

var errConsoleBridgeUnavailable = errors.New("Proxmox console bridge unavailable")

type consoleConfig struct {
	CredentialBroker   map[string]any  `json:"credential_broker,omitempty"`
	CredentialRuleID   string          `json:"credential_rule_id"`
	Console            consoleContext  `json:"console"`
	TimeoutMS          int             `json:"timeout_ms"`
	InsecureSkipVerify bool            `json:"insecure_skip_verify"`
	SSHHostKeyPolicy   string          `json:"ssh_host_key_policy"`
	PluginInputs       json.RawMessage `json:"plugin_inputs,omitempty"`
}

type consoleContext struct {
	SessionID          string `json:"session_id"`
	AgentID            string `json:"agent_id,omitempty"`
	GatewayID          string `json:"gateway_id,omitempty"`
	DeviceUID          string `json:"device_uid,omitempty"`
	TargetKind         string `json:"target_kind,omitempty"`
	ConsoleMode        string `json:"console_mode,omitempty"`
	CredentialRuleID   string `json:"credential_rule_id,omitempty"`
	PluginAssignmentID string `json:"plugin_assignment_id,omitempty"`
	Cols               uint32 `json:"cols,omitempty"`
	Rows               uint32 `json:"rows,omitempty"`
}

type consoleOpenRequest struct {
	TerminalType string `json:"terminal_type,omitempty"`
}

type consoleBridge struct {
	handle uint32
}

//export run_console
func run_console() {
	cfg := consoleConfig{
		TimeoutMS:        defaultTimeoutMS,
		SSHHostKeyPolicy: "known_hosts",
	}
	if err := sdk.LoadConfig(&cfg); err != nil {
		sdk.Log.Error("run_console configuration error: " + err.Error())
		return
	}

	if err := validateConsoleConfig(cfg); err != nil {
		sdk.Log.Error("run_console validation error: " + err.Error())
		return
	}

	bridge, err := openProxmoxConsole(consoleOpenRequest{TerminalType: "xterm-256color"})
	if err != nil {
		sdk.Log.Error("run_console open failed: " + err.Error())
		return
	}
	defer bridge.Close("plugin exited")

	message := "ServiceRadar Proxmox console plugin is installed, but the SSH/termproxy connector is not enabled in this build.\r\n"
	if err := bridge.Write([]byte(message)); err != nil {
		sdk.Log.Error("run_console write failed: " + err.Error())
	}
}

func validateConsoleConfig(cfg consoleConfig) error {
	if strings.TrimSpace(cfg.CredentialRuleID) == "" && strings.TrimSpace(cfg.Console.CredentialRuleID) == "" {
		return errors.New("credential_rule_id is required")
	}
	if len(cfg.CredentialBroker) == 0 {
		return errors.New("credential_broker is required")
	}
	if strings.TrimSpace(cfg.Console.SessionID) == "" {
		return errors.New("console.session_id is required")
	}
	if cfg.TimeoutMS > maxTimeoutMS {
		return errors.New("timeout_ms exceeds maximum")
	}
	return nil
}

func openProxmoxConsole(req consoleOpenRequest) (*consoleBridge, error) {
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	res := hostProxmoxConsoleOpen(ptrFromBytes(payload), uint32(len(payload)))
	if res <= 0 {
		return nil, errConsoleBridgeUnavailable
	}
	return &consoleBridge{handle: uint32(res)}, nil
}

func (c *consoleBridge) Write(payload []byte) error {
	if c == nil || c.handle == 0 {
		return errConsoleBridgeUnavailable
	}
	if len(payload) == 0 {
		return nil
	}
	res := hostProxmoxConsoleWrite(c.handle, ptrFromBytes(payload), uint32(len(payload)))
	if res < 0 {
		return errConsoleBridgeUnavailable
	}
	return nil
}

func (c *consoleBridge) Read(buf []byte, timeout time.Duration) (int, error) {
	if c == nil || c.handle == 0 {
		return 0, errConsoleBridgeUnavailable
	}
	if len(buf) == 0 {
		return 0, nil
	}
	res := hostProxmoxConsoleRead(c.handle, ptrFromBytes(buf), uint32(len(buf)), uint32(timeout.Milliseconds()))
	if res < 0 {
		return 0, errConsoleBridgeUnavailable
	}
	return int(res), nil
}

func (c *consoleBridge) Close(reason string) error {
	if c == nil || c.handle == 0 {
		return nil
	}
	payload := []byte(reason)
	res := hostProxmoxConsoleClose(c.handle, ptrFromBytes(payload), uint32(len(payload)))
	c.handle = 0
	if res < 0 {
		return errConsoleBridgeUnavailable
	}
	return nil
}

func ptrFromBytes(data []byte) uint32 {
	if len(data) == 0 {
		return 0
	}
	return uint32(uintptr(unsafe.Pointer(&data[0])))
}
