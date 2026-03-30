package edgeonboarding

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	ErrBundleDownloadFailed = errors.New("bundle download failed")
	ErrConfigAlreadyExists  = errors.New("config already exists")
	ErrCertsAlreadyExist    = errors.New("certs already exist")
	ErrBundleMissingConfig  = errors.New("bundle missing config.json")
	ErrBundleMissingCerts   = errors.New("bundle missing certificate files")
	ErrCoreAPIHostRequired  = errors.New("core API host is required")
)

const (
	defaultAgentOverridesPath = "/etc/serviceradar/kv-overrides.env"
	bundleAgentOverridesName  = "/config/agent-env-overrides.env"
	releasePublicKeyEnv       = "SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY"
)

// EnrollOptions controls the agent enrollment workflow.
type EnrollOptions struct {
	Token         string
	CoreHost      string
	HostIP        string
	ConfigPath    string
	CertDir       string
	OverridesPath string
	HTTPClient    *http.Client
	Logf          func(string, ...interface{})
	Errorf        func(string, ...interface{})
	SkipOverwrite bool
}

// EnrollAgentFromToken downloads an edge onboarding bundle and writes agent config + certs.
func EnrollAgentFromToken(ctx context.Context, opts EnrollOptions) error {
	payload, err := parseOnboardingToken(opts.Token, "", opts.CoreHost)
	if err != nil {
		return fmt.Errorf("parse onboarding token: %w", err)
	}

	baseURL, err := normalizeCoreURL(payload.CoreURL)
	if err != nil {
		return fmt.Errorf("resolve core API host: %w", err)
	}

	bundleURL := fmt.Sprintf(
		"%s/api/edge-packages/%s/bundle",
		strings.TrimRight(baseURL, "/"),
		payload.PackageID,
	)

	req, err := newBundleDownloadRequest(ctx, bundleURL, payload.DownloadToken)
	if err != nil {
		return err
	}

	client := opts.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download bundle: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("%w (%s): %s", ErrBundleDownloadFailed, resp.Status, strings.TrimSpace(string(body)))
	}

	bundle, err := extractBundle(resp.Body)
	if err != nil {
		return err
	}

	updatedConfig, certDir, err := updateAgentConfig(bundle.ConfigJSON, opts.HostIP, opts.CertDir)
	if err != nil {
		return err
	}

	overridesPath := resolveAgentOverridesPath(opts.OverridesPath)
	overrideUpdates := extractEnvOverrides(bundle.EnvOverrides)

	if opts.SkipOverwrite {
		if fileExists(opts.ConfigPath) {
			backupPath, err := backupFile(opts.ConfigPath)
			if err != nil {
				return err
			}
			if opts.Logf != nil && backupPath != "" {
				opts.Logf("Existing agent config backed up to %s", backupPath)
			}
		}
		if anyCertExists(certDir) {
			backupDir, err := backupDirectory(certDir)
			if err != nil {
				return err
			}
			if opts.Logf != nil && backupDir != "" {
				opts.Logf("Existing agent certs backed up to %s", backupDir)
			}
		}
	}

	if err := writeFileAtomic(opts.ConfigPath, updatedConfig, 0644); err != nil {
		return fmt.Errorf("write agent config: %w", err)
	}

	if err := os.MkdirAll(certDir, 0755); err != nil {
		return fmt.Errorf("create cert dir: %w", err)
	}

	if err := writeFileAtomic(filepath.Join(certDir, "component.pem"), bundle.ComponentCert, 0644); err != nil {
		return fmt.Errorf("write component cert: %w", err)
	}
	if err := writeFileAtomic(filepath.Join(certDir, "component-key.pem"), bundle.ComponentKey, 0600); err != nil {
		return fmt.Errorf("write component key: %w", err)
	}
	if err := writeFileAtomic(filepath.Join(certDir, "ca-chain.pem"), bundle.CAChain, 0644); err != nil {
		return fmt.Errorf("write CA chain: %w", err)
	}

	if len(overrideUpdates) > 0 {
		if err := writeAgentOverrides(overridesPath, overrideUpdates); err != nil {
			return err
		}
	}

	if err := chownAgentAssets(opts.ConfigPath, certDir, overridesPath, opts.Logf); err != nil {
		return err
	}

	if err := restartAgentService(ctx, opts.Logf); err != nil {
		return err
	}

	if opts.Logf != nil {
		opts.Logf("Agent enrollment complete. Wrote config to %s and certs to %s", opts.ConfigPath, certDir)
	}

	return nil
}

type bundlePayload struct {
	ConfigJSON    []byte
	ComponentCert []byte
	ComponentKey  []byte
	CAChain       []byte
	EnvOverrides  []byte
}

func extractBundle(reader io.Reader) (*bundlePayload, error) {
	gzr, err := gzip.NewReader(reader)
	if err != nil {
		return nil, fmt.Errorf("open bundle gzip: %w", err)
	}
	defer func() { _ = gzr.Close() }()

	tr := tar.NewReader(gzr)
	payload := &bundlePayload{}

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read bundle tar: %w", err)
		}
		if hdr == nil || hdr.FileInfo().IsDir() {
			continue
		}

		name := filepath.ToSlash(hdr.Name)
		switch {
		case strings.HasSuffix(name, "/config/config.json"):
			payload.ConfigJSON, err = io.ReadAll(tr)
		case strings.HasSuffix(name, "/certs/component.pem"):
			payload.ComponentCert, err = io.ReadAll(tr)
		case strings.HasSuffix(name, "/certs/component-key.pem"):
			payload.ComponentKey, err = io.ReadAll(tr)
		case strings.HasSuffix(name, "/certs/ca-chain.pem"):
			payload.CAChain, err = io.ReadAll(tr)
		case strings.HasSuffix(name, bundleAgentOverridesName):
			payload.EnvOverrides, err = io.ReadAll(tr)
		default:
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("read bundle file %s: %w", name, err)
		}
	}

	if len(payload.ConfigJSON) == 0 {
		return nil, ErrBundleMissingConfig
	}
	if len(payload.ComponentCert) == 0 || len(payload.ComponentKey) == 0 || len(payload.CAChain) == 0 {
		return nil, ErrBundleMissingCerts
	}

	return payload, nil
}

func updateAgentConfig(configJSON []byte, hostIPOverride, certDirOverride string) ([]byte, string, error) {
	var config map[string]interface{}
	if err := json.Unmarshal(configJSON, &config); err != nil {
		return nil, "", fmt.Errorf("parse config.json: %w", err)
	}

	certDir := "/etc/serviceradar/certs"
	if gatewaySecurity, ok := config["gateway_security"].(map[string]interface{}); ok {
		if dir, ok := gatewaySecurity["cert_dir"].(string); ok && strings.TrimSpace(dir) != "" {
			certDir = strings.TrimSpace(dir)
		}
	}

	if strings.TrimSpace(certDirOverride) != "" {
		certDir = strings.TrimSpace(certDirOverride)
		if gatewaySecurity, ok := config["gateway_security"].(map[string]interface{}); ok {
			gatewaySecurity["cert_dir"] = certDir
			config["gateway_security"] = gatewaySecurity
		}
	}

	if hostIPOverride == "" {
		hostIPOverride = detectHostIP()
	}

	if hostIPOverride != "" {
		if value, ok := config["host_ip"].(string); !ok || value == "" || value == "PLACEHOLDER_HOST_IP" {
			config["host_ip"] = hostIPOverride
		}
	}

	updated, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, "", fmt.Errorf("serialize agent config: %w", err)
	}

	return updated, certDir, nil
}

func resolveAgentOverridesPath(path string) string {
	if strings.TrimSpace(path) == "" {
		return defaultAgentOverridesPath
	}

	return strings.TrimSpace(path)
}

func extractEnvOverrides(content []byte) map[string]string {
	updates := make(map[string]string)
	allowedKeys := map[string]struct{}{
		releasePublicKeyEnv: {},
	}

	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}

		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if key == "" {
			continue
		}

		if _, allowed := allowedKeys[key]; !allowed {
			continue
		}

		updates[key] = value
	}

	return updates
}

func writeAgentOverrides(path string, updates map[string]string) error {
	if len(updates) == 0 {
		return nil
	}

	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read agent overrides: %w", err)
	}

	merged := mergeEnvOverrides(existing, updates)
	if err := writeFileAtomic(path, merged, 0644); err != nil {
		return fmt.Errorf("write agent overrides: %w", err)
	}

	return nil
}

func mergeEnvOverrides(existing []byte, updates map[string]string) []byte {
	if len(updates) == 0 {
		return append([]byte(nil), existing...)
	}

	lines := strings.Split(string(existing), "\n")
	output := make([]string, 0, len(lines)+len(updates))
	remaining := make(map[string]string, len(updates))

	for key, value := range updates {
		remaining[key] = value
	}

	for _, line := range lines {
		if line == "" {
			continue
		}

		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			output = append(output, line)
			continue
		}

		key, _, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			output = append(output, line)
			continue
		}

		if replacement, exists := remaining[key]; exists {
			output = append(output, fmt.Sprintf("%s=%s", key, replacement))
			delete(remaining, key)
			continue
		}

		output = append(output, line)
	}

	for key, value := range remaining {
		output = append(output, fmt.Sprintf("%s=%s", key, value))
	}

	if len(output) == 0 {
		return nil
	}

	return []byte(strings.Join(output, "\n") + "\n")
}

func detectHostIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ip := extractIPv4(addr)
			if ip != "" {
				return ip
			}
		}
	}
	return ""
}

func extractIPv4(addr net.Addr) string {
	switch v := addr.(type) {
	case *net.IPNet:
		return ipv4String(v.IP)
	case *net.IPAddr:
		return ipv4String(v.IP)
	default:
		return ""
	}
}

func ipv4String(ip net.IP) string {
	if ip == nil {
		return ""
	}
	ip = ip.To4()
	if ip == nil || ip.IsLoopback() {
		return ""
	}
	return ip.String()
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("create dir %s: %w", dir, err)
	}

	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}

	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("sync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return fmt.Errorf("chmod temp file: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("rename temp file: %w", err)
	}

	return nil
}

func normalizeCoreURL(raw string) (string, error) {
	return normalizeBaseURL(raw)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func anyCertExists(certDir string) bool {
	if certDir == "" {
		return false
	}

	paths := []string{
		filepath.Join(certDir, "component.pem"),
		filepath.Join(certDir, "component-key.pem"),
		filepath.Join(certDir, "ca-chain.pem"),
	}

	for _, path := range paths {
		if fileExists(path) {
			return true
		}
	}

	return false
}

func backupFile(path string) (string, error) {
	backup := backupName(path)
	if backup == "" {
		return "", nil
	}
	if err := os.Rename(path, backup); err != nil {
		return "", fmt.Errorf("backup file %s: %w", path, err)
	}
	return backup, nil
}

func backupDirectory(path string) (string, error) {
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("stat dir %s: %w", path, err)
	}
	backup := backupName(path)
	if backup == "" {
		return "", nil
	}
	if err := os.Rename(path, backup); err != nil {
		return "", fmt.Errorf("backup dir %s: %w", path, err)
	}
	return backup, nil
}

func backupName(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	ts := time.Now().UTC().Format("20060102-150405")
	return fmt.Sprintf("%s.bak.%s", path, ts)
}

func chownAgentAssets(configPath, certDir, overridesPath string, logf func(string, ...interface{})) error {
	if os.Geteuid() != 0 {
		return nil
	}

	uid, gid, ok, err := lookupUserIDs("serviceradar")
	if err != nil {
		return err
	}
	if !ok {
		if logf != nil {
			logf("serviceradar user not found; skipping ownership update")
		}
		return nil
	}

	paths := []string{
		configPath,
		certDir,
		overridesPath,
		filepath.Join(certDir, "component.pem"),
		filepath.Join(certDir, "component-key.pem"),
		filepath.Join(certDir, "ca-chain.pem"),
	}

	for _, path := range paths {
		if strings.TrimSpace(path) == "" {
			continue
		}
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("stat %s: %w", path, err)
		}
		if err := os.Chown(path, uid, gid); err != nil {
			return fmt.Errorf("chown %s: %w", path, err)
		}
	}

	if logf != nil {
		logf("Updated ownership for agent config/certs to serviceradar")
	}

	return nil
}

func lookupUserIDs(name string) (int, int, bool, error) {
	data, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return 0, 0, false, fmt.Errorf("read /etc/passwd: %w", err)
	}

	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, ":")
		if len(fields) < 4 || fields[0] != name {
			continue
		}
		uid, err := strconv.Atoi(fields[2])
		if err != nil {
			return 0, 0, false, fmt.Errorf("parse uid for %s: %w", name, err)
		}
		gid, err := strconv.Atoi(fields[3])
		if err != nil {
			return 0, 0, false, fmt.Errorf("parse gid for %s: %w", name, err)
		}
		return uid, gid, true, nil
	}

	return 0, 0, false, nil
}

func restartAgentService(ctx context.Context, logf func(string, ...interface{})) error {
	if _, err := exec.LookPath("systemctl"); err != nil {
		if logf != nil {
			logf("systemctl not found; skipping agent restart")
		}
		return nil
	}

	cmd := exec.CommandContext(ctx, "systemctl", "restart", "serviceradar-agent")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("restart serviceradar-agent: %w: %s", err, strings.TrimSpace(string(output)))
	}

	if logf != nil {
		logf("Restarted serviceradar-agent")
	}

	return nil
}
