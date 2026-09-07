package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

var errConsoleBridgeUnavailable = errors.New("Proxmox console bridge unavailable")
var errConsoleConnectorUnsupported = errors.New("Proxmox console connector is not configured")

type consoleConfig struct {
	CredentialRuleID string          `json:"credential_rule_id"`
	APIToken         string          `json:"api_token,omitempty"`
	HostCredential   string          `json:"credential_secret,omitempty"`
	Console          consoleContext  `json:"console"`
	Target           consoleTarget   `json:"target,omitempty"`
	TimeoutMS        int             `json:"timeout_ms"`
	PluginInputs     json.RawMessage `json:"plugin_inputs,omitempty"`
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
	DeviceUID               string `json:"device_uid,omitempty"`
	BaseURL                 string `json:"base_url,omitempty"`
	Hostname                string `json:"hostname,omitempty"`
	IP                      string `json:"ip,omitempty"`
	SSHPort                 int    `json:"ssh_port,omitempty"`
	ProviderRef             string `json:"provider_ref,omitempty"`
	TargetRef               string `json:"target_ref,omitempty"`
	TargetKind              string `json:"target_kind,omitempty"`
	ConsoleMode             string `json:"console_mode,omitempty"`
	IntegrationID           string `json:"integration_id,omitempty"`
	Cluster                 string `json:"cluster,omitempty"`
	Node                    string `json:"node,omitempty"`
	OwnerNode               string `json:"owner_node,omitempty"`
	VMID                    int    `json:"vmid,omitempty"`
	ControllerDeviceUID     string `json:"controller_device_uid,omitempty"`
	ControllerRef           string `json:"controller_ref,omitempty"`
	ControllerIntegrationID string `json:"controller_integration_id,omitempty"`
	ControllerID            string `json:"controller_id,omitempty"`
	ProviderInstanceRef     string `json:"provider_instance_ref,omitempty"`
	NativeClusterID         string `json:"native_cluster_id,omitempty"`
	ObjectKind              string `json:"object_kind,omitempty"`
	NativeObjectID          string `json:"native_object_id,omitempty"`
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
	dialWS     func(context.Context, sdk.WebSocketDialRequest, time.Duration) (websocketConsoleConn, error)
}

type websocketConsoleConn interface {
	SendContext(context.Context, []byte, time.Duration) error
	RecvContext(context.Context, []byte, time.Duration) (int, error)
	Close() error
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
	if deps.dialWS == nil {
		deps.dialWS = func(ctx context.Context, req sdk.WebSocketDialRequest, timeout time.Duration) (websocketConsoleConn, error) {
			return sdk.WebSocketDialRequestContext(ctx, req, timeout)
		}
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
		return streamProxmoxAPIConsole(cfg, bridge, deps.dialWS)
	default:
		return fmt.Errorf("unsupported console mode %q", cfg.Console.ConsoleMode)
	}
}

func validateConsoleConfig(cfg consoleConfig) error {
	credentialRuleID := strings.TrimSpace(cfg.CredentialRuleID)
	consoleCredentialRuleID := strings.TrimSpace(cfg.Console.CredentialRuleID)
	if credentialRuleID == "" || consoleCredentialRuleID == "" || credentialRuleID != consoleCredentialRuleID {
		return errors.New("credential_rule_id is required")
	}
	if strings.TrimSpace(cfg.Console.SessionID) == "" {
		return errors.New("console.session_id is required")
	}
	if strings.TrimSpace(cfg.Console.PluginAssignmentID) == "" {
		return errors.New("console.plugin_assignment_id is required")
	}
	if strings.TrimSpace(cfg.Target.Hostname) == "" && strings.TrimSpace(cfg.Target.IP) == "" && strings.TrimSpace(cfg.Target.BaseURL) == "" {
		return errors.New("console target host is required")
	}
	if cfg.TimeoutMS > maxTimeoutMS {
		return errors.New("timeout_ms exceeds maximum")
	}
	switch strings.TrimSpace(cfg.Console.ConsoleMode) {
	case "", "ssh":
		if cfg.HostCredential != hostCredentialSentinel {
			return errors.New("SSH console requires the host credential sentinel")
		}
	case "proxmox_termproxy", "proxmox_vncwebsocket":
		if cfg.APIToken != hostCredentialSentinel {
			return errors.New("Proxmox API console requires the host credential sentinel")
		}
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
	return consoleConfig{TimeoutMS: defaultTimeoutMS}
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
	if containsForbiddenProxmoxPublicConfigValue(raw) {
		return errors.New("legacy credential or TLS override is forbidden")
	}
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
			ProviderRef: firstNonEmpty(
				stringValue(input.Item, "provider_ref"),
				stringValue(input.Item, "target_ref"),
			),
			TargetRef:           stringValue(input.Item, "target_ref"),
			TargetKind:          stringValue(input.Item, "target_kind"),
			ConsoleMode:         stringValue(input.Item, "console_mode"),
			IntegrationID:       stringValue(input.Item, "integration_id"),
			Cluster:             stringValue(input.Item, "cluster"),
			Node:                stringValue(input.Item, "node"),
			OwnerNode:           stringValue(input.Item, "owner_node"),
			VMID:                intValue(input.Item, "vmid"),
			ControllerID:        stringValue(input.Item, "controller_id"),
			ProviderInstanceRef: stringValue(input.Item, "provider_instance_ref"),
			NativeClusterID:     stringValue(input.Item, "native_cluster_id"),
			ObjectKind:          stringValue(input.Item, "object_kind"),
			NativeObjectID:      stringValue(input.Item, "native_object_id"),
		}
	}
	return consoleTarget{}
}

type proxmoxConsoleProxyResponse struct {
	Data struct {
		Port   json.Number `json:"port"`
		Ticket string      `json:"ticket"`
		User   string      `json:"user"`
		UPID   string      `json:"upid"`
		Cert   string      `json:"cert"`
	} `json:"data"`
}

type proxmoxConsoleTargetRef struct {
	Cluster    string
	Node       string
	TargetKind string
	VMID       int
}

func streamProxmoxAPIConsole(
	cfg consoleConfig,
	bridge proxmoxConsoleBridge,
	dial func(context.Context, sdk.WebSocketDialRequest, time.Duration) (websocketConsoleConn, error),
) error {
	token := normalizeProxmoxAPIToken(cfg.APIToken)
	if token == "" {
		_ = bridge.Write([]byte("Unable to open Proxmox console: Proxmox API token is required.\r\n"))
		return errMissingToken
	}

	baseURL := consoleBaseURL(cfg.Target)
	if baseURL == "" {
		return errors.New("Proxmox console target base_url is required")
	}

	target, err := resolveProxmoxConsoleTarget(cfg)
	if err != nil {
		_ = bridge.Write([]byte("Unable to resolve Proxmox console target: " + err.Error() + "\r\n"))
		return err
	}

	proxyPath, wsPath, err := proxmoxConsolePaths(
		cfg.Console.ConsoleMode,
		normalizeProxmoxTargetKind(firstNonEmpty(cfg.Console.TargetKind, cfg.Target.TargetKind, target.TargetKind)),
		target,
	)
	if err != nil {
		_ = bridge.Write([]byte("Unsupported Proxmox console target: " + err.Error() + "\r\n"))
		return err
	}

	timeout := time.Duration(normalizeConsoleTimeoutMS(cfg.TimeoutMS)) * time.Millisecond
	proxy, err := requestProxmoxConsoleProxy(cfg, baseURL, token, proxyPath)
	if err != nil {
		_ = bridge.Write([]byte("Unable to create Proxmox console proxy: " + sanitizeError(err) + "\r\n"))
		return err
	}

	port := strings.TrimSpace(proxy.Data.Port.String())
	if port == "" || proxy.Data.Ticket != hostProxmoxTicketSentinel {
		return errors.New("Proxmox console proxy response did not include a host-bound ticket handle")
	}

	wsURL, err := proxmoxConsoleWebSocketURL(baseURL, wsPath, port, proxy.Data.Ticket)
	if err != nil {
		return err
	}

	ctx := context.Background()
	ws, err := dial(ctx, sdk.WebSocketDialRequest{
		URL:                wsURL,
		Headers:            map[string]string{"Authorization": token},
		InsecureSkipVerify: false,
	}, timeout)
	if err != nil {
		_ = bridge.Write([]byte("Unable to connect Proxmox console websocket: " + sanitizeError(err) + "\r\n"))
		return err
	}
	defer ws.Close()

	inputBuf := make([]byte, 32*1024)
	wsBuf := make([]byte, 32*1024)
	for {
		if n, recvErr := ws.RecvContext(ctx, wsBuf, 50*time.Millisecond); n > 0 {
			if err := bridge.Write(wsBuf[:n]); err != nil {
				return err
			}
		} else if recvErr != nil && !consoleTimeoutError(recvErr) {
			return recvErr
		}

		n, err := bridge.Read(inputBuf, 250*time.Millisecond)
		if errors.Is(err, errConsoleBridgeUnavailable) {
			return err
		}
		if err != nil || n == 0 {
			continue
		}

		var frame consoleInputFrame
		if err := json.Unmarshal(inputBuf[:n], &frame); err != nil {
			continue
		}

		switch frame.FrameType {
		case "data":
			if len(frame.Data) > 0 {
				if err := ws.SendContext(ctx, frame.Data, timeout); err != nil {
					return err
				}
			}
		case "close":
			return nil
		case "resize":
			// Proxmox termproxy/vncwebsocket does not expose a generic resize ABI here.
		}
	}
}

func consoleTimeoutError(err error) bool {
	var hostErr sdk.HostError
	if errors.As(err, &hostErr) && hostErr.Code == -6 {
		return true
	}
	return false
}

func requestProxmoxConsoleProxy(cfg consoleConfig, baseURL, token, path string) (proxmoxConsoleProxyResponse, error) {
	var out proxmoxConsoleProxyResponse
	resp, err := proxmoxHTTP.Do(sdk.HTTPRequest{
		Method:             http.MethodPost,
		URL:                strings.TrimRight(baseURL, "/") + path,
		Headers:            map[string]string{"Authorization": token, "Accept": "application/json"},
		TimeoutMS:          normalizeConsoleTimeoutMS(cfg.TimeoutMS),
		InsecureSkipVerify: false,
	})
	if err != nil {
		return out, err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return out, fmt.Errorf("HTTP %d%s", resp.Status, responseBodySuffix(resp.Body))
	}
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		return out, fmt.Errorf("decode proxy response: %w", err)
	}
	return out, nil
}

func proxmoxConsolePaths(mode, targetKind string, target proxmoxConsoleTargetRef) (string, string, error) {
	node := url.PathEscape(target.Node)
	switch strings.TrimSpace(mode) {
	case "proxmox_termproxy":
		if targetKind == "lxc_guest" {
			vmid := strconv.Itoa(target.VMID)
			return "/api2/json/nodes/" + node + "/lxc/" + vmid + "/termproxy",
				"/api2/json/nodes/" + node + "/lxc/" + vmid + "/vncwebsocket", nil
		}
		return "/api2/json/nodes/" + node + "/termproxy",
			"/api2/json/nodes/" + node + "/vncwebsocket", nil
	case "proxmox_vncwebsocket":
		if targetKind != "qemu_guest" || target.VMID <= 0 {
			return "", "", errors.New("qemu_guest vmid is required for vncwebsocket")
		}
		vmid := strconv.Itoa(target.VMID)
		return "/api2/json/nodes/" + node + "/qemu/" + vmid + "/vncproxy",
			"/api2/json/nodes/" + node + "/qemu/" + vmid + "/vncwebsocket", nil
	default:
		return "", "", fmt.Errorf("unsupported mode %q", mode)
	}
}

func proxmoxConsoleWebSocketURL(baseURL, path, port, ticket string) (string, error) {
	parsedPort, err := strconv.Atoi(port)
	if err != nil || parsedPort <= 0 || parsedPort > 65535 || strconv.Itoa(parsedPort) != port ||
		ticket != hostProxmoxTicketSentinel {
		return "", errors.New("invalid host-bound Proxmox console ticket handle")
	}
	parsed, err := url.Parse(strings.TrimRight(baseURL, "/") + path)
	if err != nil {
		return "", err
	}
	switch parsed.Scheme {
	case "https":
		parsed.Scheme = "wss"
	default:
		return "", fmt.Errorf("unsupported Proxmox URL scheme %q", parsed.Scheme)
	}
	query := parsed.Query()
	query.Set("port", port)
	query.Set("vncticket", ticket)
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

func resolveProxmoxConsoleTarget(cfg consoleConfig) (proxmoxConsoleTargetRef, error) {
	ref := firstNonEmpty(cfg.Target.ProviderRef, cfg.Target.TargetRef)
	target := proxmoxConsoleTargetRef{
		Cluster:    strings.TrimSpace(cfg.Target.Cluster),
		Node:       strings.TrimSpace(firstNonEmpty(cfg.Target.Node, cfg.Target.OwnerNode)),
		TargetKind: normalizeProxmoxTargetKind(firstNonEmpty(cfg.Target.TargetKind, cfg.Console.TargetKind)),
		VMID:       cfg.Target.VMID,
	}
	if cfg.Target.Node != "" && cfg.Target.OwnerNode != "" &&
		strings.TrimSpace(cfg.Target.Node) != strings.TrimSpace(cfg.Target.OwnerNode) {
		return proxmoxConsoleTargetRef{}, errors.New("conflicting Proxmox owner nodes")
	}
	if target.VMID < 0 {
		return proxmoxConsoleTargetRef{}, errors.New("invalid vmid")
	}
	if parsed, ok := parseProxmoxProviderRef(ref); ok {
		if err := mergeProxmoxConsoleTargetRef(&target, parsed); err != nil {
			return proxmoxConsoleTargetRef{}, err
		}
	}

	if target.Node == "" && target.TargetKind == "pve_host" {
		target.Node = strings.TrimSpace(firstNonEmpty(cfg.Target.Hostname, cfg.Target.IP))
	}
	if target.Node == "" && target.TargetKind == "pve_host" && strings.TrimSpace(cfg.Target.BaseURL) != "" {
		if parsedURL, err := url.Parse(cfg.Target.BaseURL); err == nil {
			target.Node = parsedURL.Hostname()
		}
	}
	if target.Node == "" {
		return proxmoxConsoleTargetRef{}, errors.New("node is required")
	}
	return target, nil
}

func mergeProxmoxConsoleTargetRef(target *proxmoxConsoleTargetRef, parsed proxmoxConsoleTargetRef) error {
	if target == nil {
		return errors.New("target is required")
	}
	if parsed.Cluster != "" {
		if target.Cluster != "" && target.Cluster != parsed.Cluster {
			return errors.New("provider_ref cluster does not match target")
		}
		target.Cluster = parsed.Cluster
	}
	if parsed.Node != "" {
		if target.Node != "" && target.Node != parsed.Node {
			return errors.New("provider_ref node does not match target")
		}
		target.Node = parsed.Node
	}
	if parsed.TargetKind != "" {
		if target.TargetKind != "" && target.TargetKind != parsed.TargetKind {
			return errors.New("provider_ref kind does not match target")
		}
		target.TargetKind = parsed.TargetKind
	}
	if parsed.VMID > 0 {
		if target.VMID > 0 && target.VMID != parsed.VMID {
			return errors.New("provider_ref vmid does not match target")
		}
		target.VMID = parsed.VMID
	}
	return nil
}

func parseProxmoxProviderRef(ref string) (proxmoxConsoleTargetRef, bool) {
	parts := strings.Split(strings.TrimSpace(ref), ":")
	if len(parts) < 3 || parts[0] != "proxmox" {
		return proxmoxConsoleTargetRef{}, false
	}
	if parts[1] == "node" && len(parts) == 3 && parts[2] != "" {
		return proxmoxConsoleTargetRef{Node: parts[2], TargetKind: "pve_host"}, true
	}
	if parts[1] == "guest" && len(parts) == 5 {
		vmid, err := strconv.Atoi(parts[4])
		if err != nil || vmid <= 0 {
			return proxmoxConsoleTargetRef{}, false
		}
		kind := normalizeProxmoxTargetKind(parts[3])
		if kind != "qemu_guest" && kind != "lxc_guest" {
			return proxmoxConsoleTargetRef{}, false
		}
		return proxmoxConsoleTargetRef{Node: parts[2], TargetKind: kind, VMID: vmid}, true
	}
	if parts[1] == "v3" && len(parts) == 7 && parts[2] != "" && parts[3] != "" {
		cluster, clusterErr := url.PathUnescape(parts[4])
		nativeID, nativeIDErr := url.PathUnescape(parts[6])
		if clusterErr != nil || nativeIDErr != nil || cluster == "" || nativeID == "" {
			return proxmoxConsoleTargetRef{}, false
		}
		switch parts[5] {
		case "node":
			return proxmoxConsoleTargetRef{Cluster: cluster, Node: nativeID, TargetKind: "pve_host"}, true
		case "qemu", "lxc":
			vmid, err := strconv.Atoi(nativeID)
			if err != nil || vmid <= 0 {
				return proxmoxConsoleTargetRef{}, false
			}
			return proxmoxConsoleTargetRef{
				Cluster:    cluster,
				TargetKind: normalizeProxmoxTargetKind(parts[5]),
				VMID:       vmid,
			}, true
		default:
			return proxmoxConsoleTargetRef{}, false
		}
	}
	if parts[1] == "v2" && len(parts) == 5 && parts[2] != "" {
		cluster, clusterErr := url.PathUnescape(parts[2])
		nativeID, nativeIDErr := url.PathUnescape(parts[4])
		if clusterErr != nil || nativeIDErr != nil || cluster == "" || nativeID == "" {
			return proxmoxConsoleTargetRef{}, false
		}
		switch parts[3] {
		case "node":
			return proxmoxConsoleTargetRef{Cluster: cluster, Node: nativeID, TargetKind: "pve_host"}, true
		case "vm", "qemu", "lxc":
			vmid, err := strconv.Atoi(nativeID)
			if err != nil || vmid <= 0 {
				return proxmoxConsoleTargetRef{}, false
			}
			return proxmoxConsoleTargetRef{
				Cluster:    cluster,
				TargetKind: normalizeProxmoxTargetKind(parts[3]),
				VMID:       vmid,
			}, true
		default:
			return proxmoxConsoleTargetRef{}, false
		}
	}
	if parts[1] == "cluster" && len(parts) == 5 && parts[2] != "" &&
		parts[3] == "node" && parts[4] != "" {
		return proxmoxConsoleTargetRef{Cluster: parts[2], Node: parts[4], TargetKind: "pve_host"}, true
	}
	if parts[1] == "cluster" && len(parts) == 7 && parts[2] != "" &&
		parts[3] == "guest" && parts[4] != "" {
		vmid, err := strconv.Atoi(parts[6])
		if err != nil || vmid <= 0 {
			return proxmoxConsoleTargetRef{}, false
		}
		kind := normalizeProxmoxTargetKind(parts[5])
		if kind != "qemu_guest" && kind != "lxc_guest" {
			return proxmoxConsoleTargetRef{}, false
		}
		return proxmoxConsoleTargetRef{Cluster: parts[2], Node: parts[4], TargetKind: kind, VMID: vmid}, true
	}
	return proxmoxConsoleTargetRef{}, false
}

func normalizeProxmoxTargetKind(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "qemu", "vm", "qemu_guest":
		return "qemu_guest"
	case "lxc", "container", "lxc_guest":
		return "lxc_guest"
	case "node", "host", "pve_host":
		return "pve_host"
	default:
		return ""
	}
}

func consoleBaseURL(target consoleTarget) string {
	return normalizeBaseURL(firstNonEmpty(target.BaseURL, target.IP, target.Hostname))
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
