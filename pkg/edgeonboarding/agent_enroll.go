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
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/edgeonboarding/mtls"
)

// EnrollOptions controls the agent enrollment workflow.
type EnrollOptions struct {
	Token         string
	CoreHost      string
	HostIP        string
	ConfigPath    string
	CertDir       string
	HTTPClient    *http.Client
	Logf          func(string, ...interface{})
	Errorf        func(string, ...interface{})
	SkipOverwrite bool
}

// EnrollAgentFromToken downloads an edge onboarding bundle and writes agent config + certs.
func EnrollAgentFromToken(ctx context.Context, opts EnrollOptions) error {
	payload, err := mtls.ParseToken(opts.Token, opts.CoreHost)
	if err != nil {
		return fmt.Errorf("parse onboarding token: %w", err)
	}

	baseURL, err := normalizeCoreURL(payload.CoreURL)
	if err != nil {
		return fmt.Errorf("resolve core API host: %w", err)
	}

	bundleURL := fmt.Sprintf(
		"%s/api/edge-packages/%s/bundle?token=%s",
		strings.TrimRight(baseURL, "/"),
		url.PathEscape(payload.PackageID),
		url.QueryEscape(payload.DownloadToken),
	)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, bundleURL, nil)
	if err != nil {
		return fmt.Errorf("build bundle request: %w", err)
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
		return fmt.Errorf("bundle download failed (%s): %s", resp.Status, strings.TrimSpace(string(body)))
	}

	bundle, err := extractBundle(resp.Body)
	if err != nil {
		return err
	}

	updatedConfig, certDir, err := updateAgentConfig(bundle.ConfigJSON, opts.HostIP, opts.CertDir)
	if err != nil {
		return err
	}

	if opts.SkipOverwrite {
		if fileExists(opts.ConfigPath) {
			return fmt.Errorf("config already exists at %s", opts.ConfigPath)
		}
		if anyCertExists(certDir) {
			return fmt.Errorf("certs already exist under %s", certDir)
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
		default:
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("read bundle file %s: %w", name, err)
		}
	}

	if len(payload.ConfigJSON) == 0 {
		return nil, errors.New("bundle missing config.json")
	}
	if len(payload.ComponentCert) == 0 || len(payload.ComponentKey) == 0 || len(payload.CAChain) == 0 {
		return nil, errors.New("bundle missing certificate files")
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
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", errors.New("core API host is required")
	}
	if strings.HasPrefix(trimmed, "http://") || strings.HasPrefix(trimmed, "https://") {
		return trimmed, nil
	}
	return "http://" + trimmed, nil
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
