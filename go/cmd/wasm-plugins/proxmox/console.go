package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unsafe"

	"code.carverauto.dev/carverauto/serviceradar-sdk-go/sdk"
)

var errConsoleBridgeUnavailable = errors.New("Proxmox console bridge unavailable")
var errConsoleConnectorUnsupported = errors.New("Proxmox console connector is not configured")

type consoleConfig struct {
	CredentialBroker   map[string]any  `json:"credential_broker,omitempty"`
	CredentialRuleID   string          `json:"credential_rule_id"`
	Console            consoleContext  `json:"console"`
	Target             consoleTarget   `json:"target,omitempty"`
	SSH                consoleSSH      `json:"ssh,omitempty"`
	CredentialSecret   json.RawMessage `json:"credential_secret,omitempty"`
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

type consoleTarget struct {
	DeviceUID string `json:"device_uid,omitempty"`
	BaseURL   string `json:"base_url,omitempty"`
	Hostname  string `json:"hostname,omitempty"`
	IP        string `json:"ip,omitempty"`
	SSHPort   int    `json:"ssh_port,omitempty"`
}

type consoleSSH struct {
	Username   string `json:"username,omitempty"`
	Password   string `json:"password,omitempty"`
	PrivateKey string `json:"private_key,omitempty"`
	Passphrase string `json:"passphrase,omitempty"`
}

type consoleOpenRequest struct {
	TerminalType string `json:"terminal_type,omitempty"`
}

type consoleInputFrame struct {
	FrameType string `json:"frame_type"`
	Data      []byte `json:"data,omitempty"`
	Cols      uint32 `json:"cols,omitempty"`
	Rows      uint32 `json:"rows,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

type proxmoxConsoleBridge interface {
	Write([]byte) error
	Read([]byte, time.Duration) (int, error)
	Close(string) error
}

type consoleBridge struct {
	handle uint32
}

type sshConsoleSession interface {
	StdinPipe() (io.WriteCloser, error)
	StdoutPipe() (io.Reader, error)
	StderrPipe() (io.Reader, error)
	RequestPty(term string, h, w int) error
	WindowChange(h, w int) error
	Shell() error
	Wait() error
	Close() error
}

type consoleDeps struct {
	openBridge func(consoleOpenRequest) (proxmoxConsoleBridge, error)
	dialSSH    func(consoleConfig) (sshConsoleSession, error)
}

//export run_console
func run_console() {
	cfg, err := loadConsoleConfig()
	if err != nil {
		sdk.Log.Error("run_console configuration error: " + err.Error())
		return
	}

	if err := runConsoleWithDeps(cfg, consoleDeps{
		openBridge: func(req consoleOpenRequest) (proxmoxConsoleBridge, error) {
			return openProxmoxConsole(req)
		},
		dialSSH: dialSSHConsole,
	}); err != nil {
		sdk.Log.Error("run_console failed: " + err.Error())
	}
}

func runConsoleWithDeps(cfg consoleConfig, deps consoleDeps) error {
	if err := validateConsoleConfig(cfg); err != nil {
		sdk.Log.Error("run_console validation error: " + err.Error())
		return err
	}

	if deps.openBridge == nil {
		deps.openBridge = func(req consoleOpenRequest) (proxmoxConsoleBridge, error) {
			return openProxmoxConsole(req)
		}
	}
	if deps.dialSSH == nil {
		deps.dialSSH = dialSSHConsole
	}

	bridge, err := deps.openBridge(consoleOpenRequest{TerminalType: "xterm-256color"})
	if err != nil {
		return err
	}
	defer bridge.Close("plugin exited")

	switch strings.TrimSpace(cfg.Console.ConsoleMode) {
	case "", "ssh":
		return streamSSHConsole(cfg, bridge, deps.dialSSH)
	case "proxmox_termproxy", "proxmox_vncwebsocket":
		message := "ServiceRadar Proxmox console plugin is installed, but Proxmox API console transport is not enabled in this build.\r\n"
		_ = bridge.Write([]byte(message))
		return errConsoleConnectorUnsupported
	default:
		return fmt.Errorf("unsupported console mode %q", cfg.Console.ConsoleMode)
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
	if strings.TrimSpace(cfg.Target.Hostname) == "" && strings.TrimSpace(cfg.Target.IP) == "" && strings.TrimSpace(cfg.Target.BaseURL) == "" {
		return errors.New("console target host is required")
	}
	if cfg.TimeoutMS > maxTimeoutMS {
		return errors.New("timeout_ms exceeds maximum")
	}
	return nil
}

func loadConsoleConfig() (consoleConfig, error) {
	var raw map[string]any
	if err := sdk.LoadConfig(&raw); err != nil {
		return defaultConsoleConfig(), err
	}
	if len(raw) == 0 {
		return defaultConsoleConfig(), nil
	}
	return consoleConfigFromMap(raw)
}

func defaultConsoleConfig() consoleConfig {
	return consoleConfig{TimeoutMS: defaultTimeoutMS, SSHHostKeyPolicy: "known_hosts"}
}

func consoleConfigFromMap(raw map[string]any) (consoleConfig, error) {
	cfg := defaultConsoleConfig()
	if looksLikePluginInputs(raw) {
		payload, err := sdk.ParsePluginInputsMap(raw)
		if err != nil {
			return defaultConsoleConfig(), err
		}
		if payload.Template != nil {
			if err := applyConsoleConfigMap(payload.Template, &cfg); err != nil {
				return defaultConsoleConfig(), err
			}
		}
		if rawConsole, ok := raw["console"].(map[string]any); ok {
			if err := applyConsoleConfigMap(map[string]any{"console": rawConsole}, &cfg); err != nil {
				return defaultConsoleConfig(), err
			}
		}
		cfg.Target = consoleTargetFromPluginInputs(payload, cfg.Console.DeviceUID)
		return cfg, nil
	}

	if err := applyConsoleConfigMap(raw, &cfg); err != nil {
		return defaultConsoleConfig(), err
	}
	return cfg, nil
}

func applyConsoleConfigMap(raw map[string]any, cfg *consoleConfig) error {
	encoded, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	return json.Unmarshal(encoded, cfg)
}

func consoleTargetFromPluginInputs(payload *sdk.PluginInputsPayload, deviceUID string) consoleTarget {
	if payload == nil {
		return consoleTarget{}
	}
	deviceUID = strings.TrimSpace(deviceUID)
	for _, input := range payload.FlattenItems() {
		if input.Entity != "devices" {
			continue
		}
		uid := firstNonEmpty(
			stringValue(input.Item, "uid"),
			stringValue(input.Item, "device_uid"),
			stringValue(input.Item, "device_id"),
		)
		if deviceUID != "" && uid != deviceUID {
			continue
		}
		target := targetFromInputItem(input.Item, Config{})
		return consoleTarget{
			DeviceUID: uid,
			BaseURL:   target.BaseURL,
			Hostname:  target.Hostname,
			IP: firstNonEmpty(
				stringValue(input.Item, "ip"),
				stringValue(input.Item, "device_ip"),
			),
			SSHPort: intValue(input.Item, "ssh_port"),
		}
	}
	return consoleTarget{}
}

func normalizeConsoleTimeoutMS(timeoutMS int) int {
	if timeoutMS <= 0 {
		return defaultTimeoutMS
	}
	if timeoutMS > maxTimeoutMS {
		return maxTimeoutMS
	}
	return timeoutMS
}

func intValue(values map[string]any, key string) int {
	switch value := values[key].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case float64:
		return int(value)
	case json.Number:
		parsed, _ := value.Int64()
		return int(parsed)
	default:
		return 0
	}
}

func firstNonZero32(values ...uint32) uint32 {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
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
