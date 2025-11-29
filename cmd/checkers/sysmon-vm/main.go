package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/checker/sysmonvm"
	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/pkg/cpufreq"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errSysmonDescriptorMissing = fmt.Errorf("sysmon-vm-checker descriptor missing")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("sysmon-vm checker failed: %v", err)
	}
}

func run() error {
	configPath := flag.String("config", "/etc/serviceradar/checkers/sysmon-vm.json", "Path to sysmon-vm config file")
	onboardingToken := flag.String("onboarding-token", "", "Edge onboarding token (SPIFFE path; triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	mtlsMode := flag.Bool("mtls", false, "Enable mTLS bootstrap (token or bundle required)")
	mtlsToken := flag.String("token", "", "mTLS onboarding token (edgepkg-v1)")
	mtlsHost := flag.String("host", "", "Core API host for mTLS bundle download (e.g. http://core:8090)")
	mtlsBundlePath := flag.String("bundle", "", "Path to a pre-fetched mTLS bundle (tar.gz or JSON)")
	mtlsCertDir := flag.String("cert-dir", "/etc/serviceradar/certs", "Directory to write mTLS certs/keys")
	mtlsServerName := flag.String("server-name", "sysmon-vm.serviceradar", "Server name to present in mTLS")
	flag.Parse()

	ctx := context.Background()

	var forcedSecurity *models.SecurityConfig

	if *mtlsMode {
		mtlsCfg, err := bootstrapMTLS(ctx, *mtlsToken, *mtlsHost, *mtlsBundlePath, *mtlsCertDir, *mtlsServerName)
		if err != nil {
			return fmt.Errorf("mTLS bootstrap failed: %w", err)
		}
		forcedSecurity = mtlsCfg
		log.Printf("mTLS bundle installed to %s", *mtlsCertDir)
	} else {
		// Try edge onboarding first (checks env vars if flags not set)
		onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeChecker, nil)
		if err != nil {
			return fmt.Errorf("edge onboarding failed: %w", err)
		}

		// If onboarding was performed, use the generated config
		if onboardingResult != nil {
			*configPath = onboardingResult.ConfigPath
			log.Printf("Using edge-onboarded configuration from: %s", *configPath)
			log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
		}
	}

	var cfg sysmonvm.Config
	desc, ok := config.ServiceDescriptorFor("sysmon-vm-checker")
	if !ok {
		return errSysmonDescriptorMissing
	}
	bootstrapResult, err := cfgbootstrap.Service(ctx, desc, &cfg, cfgbootstrap.ServiceOptions{
		Role:         models.RoleChecker,
		ConfigPath:   *configPath,
		DisableWatch: true,
	})
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}
	defer func() { _ = bootstrapResult.Close() }()

	if forcedSecurity != nil {
		cfg.Security = forcedSecurity
	}

	sampleInterval, err := cfg.Normalize()
	if err != nil {
		return fmt.Errorf("invalid sample interval: %w", err)
	}

	logCfg := &logger.Config{
		Level:  "info",
		Output: "stdout",
	}

	componentLogger, err := lifecycle.CreateComponentLogger(ctx, "sysmon-vm", logCfg)
	if err != nil {
		return fmt.Errorf("failed to create component logger: %w", err)
	}

	service := sysmonvm.NewService(componentLogger, sampleInterval)

	bootstrapResult.StartWatch(ctx, componentLogger, &cfg, func() {
		componentLogger.Warn().Msg("sysmon-vm config updated in KV; restart checker to apply changes")
	})

	register := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s, service)
		return nil
	}

	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              samplerService{},
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{register},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
		ServiceName:          "sysmon-vm",
	}

	if err := lifecycle.RunServer(ctx, &opts); err != nil {
		return fmt.Errorf("server shutdown: %w", err)
	}

	return nil
}

type samplerService struct{}

func (samplerService) Start(ctx context.Context) error {
	return cpufreq.StartHostfreqSampler(ctx)
}

func (samplerService) Stop(context.Context) error {
	cpufreq.StopHostfreqSampler()
	return nil
}

type mtlsBundle struct {
	CACertPEM   string            `json:"ca_cert_pem"`
	ClientCert  string            `json:"client_cert_pem"`
	ClientKey   string            `json:"client_key_pem"`
	ServerName  string            `json:"server_name"`
	Endpoints   map[string]string `json:"endpoints"`
	GeneratedAt string            `json:"generated_at"`
	ExpiresAt   string            `json:"expires_at"`
}

type edgeDeliverPayload struct {
	Package struct {
		PackageID string `json:"package_id"`
	} `json:"package"`
	MTLSBundle *mtlsBundle `json:"mtls_bundle"`
}

func bootstrapMTLS(ctx context.Context, token, host, bundlePath, certDir, serverName string) (*models.SecurityConfig, error) {
	if bundlePath != "" {
		bundle, err := loadMTLSBundleFromPath(bundlePath)
		if err != nil {
			return nil, err
		}
		return installMTLSBundle(bundle, certDir, serverName)
	}

	payload, err := parseEdgepkgToken(token, host)
	if err != nil {
		return nil, err
	}

	apiBase, err := ensureScheme(payload.CoreURL)
	if err != nil {
		return nil, err
	}

	deliverURL := fmt.Sprintf("%s/api/admin/edge-packages/%s/download?format=json", strings.TrimRight(apiBase, "/"), url.PathEscape(payload.PackageID))
	body := fmt.Sprintf(`{"download_token":"%s"}`, payload.DownloadToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, deliverURL, strings.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create deliver request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request deliver endpoint: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		buf, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("deliver endpoint returned %s: %s", resp.Status, strings.TrimSpace(string(buf)))
	}

	var payloadResp edgeDeliverPayload
	if err := json.NewDecoder(resp.Body).Decode(&payloadResp); err != nil {
		return nil, fmt.Errorf("decode deliver response: %w", err)
	}

	if payloadResp.MTLSBundle == nil {
		return nil, fmt.Errorf("mTLS bundle missing in deliver response")
	}

	return installMTLSBundle(payloadResp.MTLSBundle, certDir, serverName)
}

func installMTLSBundle(bundle *mtlsBundle, certDir, serverName string) (*models.SecurityConfig, error) {
	if bundle == nil {
		return nil, fmt.Errorf("mtls bundle missing")
	}
	if err := os.MkdirAll(certDir, 0o755); err != nil {
		return nil, fmt.Errorf("create cert dir: %w", err)
	}

	write := func(name, content string, mode os.FileMode) error {
		if strings.TrimSpace(content) == "" {
			return fmt.Errorf("bundle missing %s", name)
		}
		path := filepath.Join(certDir, name)
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			return fmt.Errorf("write %s: %w", path, err)
		}
		return nil
	}

	if serverName == "" && strings.TrimSpace(bundle.ServerName) != "" {
		serverName = strings.TrimSpace(bundle.ServerName)
	}

	if err := write("root.pem", bundle.CACertPEM, 0o644); err != nil {
		return nil, err
	}
	if err := write("sysmon-vm.pem", bundle.ClientCert, 0o644); err != nil {
		return nil, err
	}
	if err := write("sysmon-vm-key.pem", bundle.ClientKey, 0o600); err != nil {
		return nil, err
	}

	return &models.SecurityConfig{
		Mode:       models.SecurityModeMTLS,
		CertDir:    certDir,
		ServerName: serverName,
		Role:       models.RoleChecker,
		TLS: models.TLSConfig{
			CertFile:     filepath.Join(certDir, "sysmon-vm.pem"),
			KeyFile:      filepath.Join(certDir, "sysmon-vm-key.pem"),
			CAFile:       filepath.Join(certDir, "root.pem"),
			ClientCAFile: filepath.Join(certDir, "root.pem"),
		},
	}, nil
}

type tokenPayload struct {
	PackageID     string `json:"pkg"`
	DownloadToken string `json:"dl"`
	CoreURL       string `json:"api,omitempty"`
}

func parseEdgepkgToken(raw, fallbackHost string) (*tokenPayload, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, fmt.Errorf("token is required for mTLS bootstrap")
	}
	const prefix = "edgepkg-v1:"
	if !strings.HasPrefix(raw, prefix) {
		return nil, fmt.Errorf("unsupported token format (expected edgepkg-v1)")
	}
	encoded := strings.TrimPrefix(raw, prefix)
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("decode token: %w", err)
	}
	var payload tokenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("unmarshal token: %w", err)
	}
	if payload.PackageID == "" {
		return nil, fmt.Errorf("token missing package id")
	}
	if strings.TrimSpace(payload.DownloadToken) == "" {
		return nil, fmt.Errorf("token missing download token")
	}
	if payload.CoreURL == "" {
		payload.CoreURL = strings.TrimSpace(fallbackHost)
	}
	if payload.CoreURL == "" {
		return nil, fmt.Errorf("core API host is required (token missing api and --host not set)")
	}
	return &payload, nil
}

func ensureScheme(host string) (string, error) {
	host = strings.TrimSpace(host)
	if host == "" {
		return "", fmt.Errorf("core API host is required")
	}
	if strings.HasPrefix(host, "http://") || strings.HasPrefix(host, "https://") {
		return host, nil
	}
	return "http://" + host, nil
}

func loadMTLSBundleFromPath(path string) (*mtlsBundle, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open bundle: %w", err)
	}
	defer func() { _ = f.Close() }()

	if strings.HasSuffix(strings.ToLower(path), ".json") {
		var bundle mtlsBundle
		if err := json.NewDecoder(f).Decode(&bundle); err != nil {
			return nil, fmt.Errorf("decode bundle json: %w", err)
		}
		return &bundle, nil
	}

	if strings.HasSuffix(strings.ToLower(path), ".tar.gz") || strings.HasSuffix(strings.ToLower(path), ".tgz") {
		return loadMTLSBundleFromArchive(f)
	}

	// Fall back to PEM trio in a dir
	if stat, err := f.Stat(); err == nil && stat.IsDir() {
		dir := path
		read := func(name string) (string, error) {
			b, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				return "", err
			}
			return string(b), nil
		}
		ca, err := read("ca.pem")
		if err != nil {
			return nil, fmt.Errorf("read ca.pem: %w", err)
		}
		cert, err := read("client.pem")
		if err != nil {
			return nil, fmt.Errorf("read client.pem: %w", err)
		}
		key, err := read("client-key.pem")
		if err != nil {
			return nil, fmt.Errorf("read client-key.pem: %w", err)
		}
		return &mtlsBundle{CACertPEM: ca, ClientCert: cert, ClientKey: key}, nil
	}

	return nil, fmt.Errorf("unsupported bundle format (expected .json, .tar.gz, or directory with ca.pem/client.pem/client-key.pem)")
}

func loadMTLSBundleFromArchive(r io.Reader) (*mtlsBundle, error) {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return nil, fmt.Errorf("open gzip: %w", err)
	}
	defer func() { _ = gz.Close() }()

	tarReader := tar.NewReader(gz)
	var ca, cert, key string
	for {
		hdr, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read archive: %w", err)
		}
		name := strings.TrimSpace(hdr.Name)
		switch {
		case strings.HasSuffix(name, "mtls/ca.pem"):
			data, _ := io.ReadAll(tarReader)
			ca = string(data)
		case strings.HasSuffix(name, "mtls/client.pem"):
			data, _ := io.ReadAll(tarReader)
			cert = string(data)
		case strings.HasSuffix(name, "mtls/client-key.pem"):
			data, _ := io.ReadAll(tarReader)
			key = string(data)
		}
	}

	if ca == "" || cert == "" || key == "" {
		return nil, fmt.Errorf("bundle archive missing mtls/ca.pem or client cert/key")
	}

	return &mtlsBundle{
		CACertPEM:  ca,
		ClientCert: cert,
		ClientKey:  key,
	}, nil
}
