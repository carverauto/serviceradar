package edgeonboarding

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	collectorTokenV2Prefix = "collectorpkg-v2:"
)

var (
	ErrCollectorTokenInvalid         = errors.New("collector token is invalid")
	ErrCollectorTokenExpired         = errors.New("collector token is expired")
	ErrCollectorBundleDownloadFailed = errors.New("collector bundle download failed")
	ErrCollectorBundleIncomplete     = errors.New("collector bundle is incomplete")
	ErrCollectorConfigExists         = errors.New("collector config already exists")
	ErrCollectorCertsExist           = errors.New("collector certs already exist")
	ErrCollectorCredsExist           = errors.New("collector creds already exist")
)

type collectorTokenPayload struct {
	BaseURL    string `json:"u"`
	PackageID  string `json:"p"`
	Secret     string `json:"t"`
	ExpiresAt  *int64 `json:"e,omitempty"`
	ConfigFile string `json:"f,omitempty"`
}

// CollectorEnrollOptions controls collector enrollment.
type CollectorEnrollOptions struct {
	Token         string
	BaseURL       string
	ConfigDir     string
	ConfigFile    string
	CertsDir      string
	CredsDir      string
	HTTPClient    *http.Client
	Logf          func(string, ...interface{})
	SkipOverwrite bool
}

// EnrollCollectorFromToken downloads a collector bundle and installs config/creds/certs.
func EnrollCollectorFromToken(ctx context.Context, opts CollectorEnrollOptions) error {
	payload, err := parseCollectorToken(opts.Token, opts.BaseURL)
	if err != nil {
		return err
	}

	baseURL := strings.TrimRight(payload.BaseURL, "/")
	bundleURL := fmt.Sprintf(
		"%s/api/collectors/%s/bundle?token=%s",
		baseURL,
		url.PathEscape(payload.PackageID),
		url.QueryEscape(payload.Secret),
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
		return fmt.Errorf("%w (%s): %s", ErrCollectorBundleDownloadFailed, resp.Status, strings.TrimSpace(string(body)))
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}

	tempDir, err := extractCollectorBundle(data)
	if err != nil {
		return err
	}
	defer func() { _ = os.RemoveAll(tempDir) }()

	rootDir, err := findBundleRoot(tempDir)
	if err != nil {
		return err
	}

	certsSrc := filepath.Join(rootDir, "certs")
	credsSrc := filepath.Join(rootDir, "creds")
	configSrc := filepath.Join(rootDir, "config")

	preferredConfig := strings.TrimSpace(opts.ConfigFile)
	if preferredConfig == "" {
		preferredConfig = strings.TrimSpace(payload.ConfigFile)
	}

	configName, err := selectCollectorConfig(configSrc, preferredConfig)
	if err != nil {
		return err
	}

	certFile := filepath.Join(certsSrc, "collector.pem")
	keyFile := filepath.Join(certsSrc, "collector-key.pem")
	caFile := filepath.Join(certsSrc, "ca-chain.pem")
	credsFile := filepath.Join(credsSrc, "nats.creds")
	configFile := filepath.Join(configSrc, configName)

	if !fileExists(certFile) || !fileExists(keyFile) || !fileExists(caFile) || !fileExists(credsFile) || !fileExists(configFile) {
		return ErrCollectorBundleIncomplete
	}

	certsDir := defaultIfEmpty(opts.CertsDir, "/etc/serviceradar/certs")
	credsDir := defaultIfEmpty(opts.CredsDir, "/etc/serviceradar/creds")
	configDir := defaultIfEmpty(opts.ConfigDir, "/etc/serviceradar")

	if opts.SkipOverwrite {
		if fileExists(filepath.Join(configDir, configName)) {
			return fmt.Errorf("%w: %s", ErrCollectorConfigExists, filepath.Join(configDir, configName))
		}
		if anyFileExists(certsDir, "collector.pem", "collector-key.pem", "ca-chain.pem") {
			return fmt.Errorf("%w: %s", ErrCollectorCertsExist, certsDir)
		}
		if anyFileExists(credsDir, "nats.creds") {
			return fmt.Errorf("%w: %s", ErrCollectorCredsExist, credsDir)
		}
	}

	if err := os.MkdirAll(certsDir, 0755); err != nil {
		return fmt.Errorf("create certs dir: %w", err)
	}
	if err := os.MkdirAll(credsDir, 0755); err != nil {
		return fmt.Errorf("create creds dir: %w", err)
	}
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	if err := copyFileAtomic(certFile, filepath.Join(certsDir, "collector.pem"), 0644); err != nil {
		return err
	}
	if err := copyFileAtomic(keyFile, filepath.Join(certsDir, "collector-key.pem"), 0600); err != nil {
		return err
	}
	if err := copyFileAtomic(caFile, filepath.Join(certsDir, "ca-chain.pem"), 0644); err != nil {
		return err
	}
	if err := copyFileAtomic(credsFile, filepath.Join(credsDir, "nats.creds"), 0600); err != nil {
		return err
	}
	if err := copyFileAtomic(configFile, filepath.Join(configDir, configName), 0644); err != nil {
		return err
	}

	if opts.Logf != nil {
		opts.Logf("Collector enrollment complete. Wrote %s, certs to %s, creds to %s", filepath.Join(configDir, configName), certsDir, credsDir)
	}

	return nil
}

func parseCollectorToken(raw, fallbackBaseURL string) (*collectorTokenPayload, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, ErrCollectorTokenInvalid
	}

	if strings.HasPrefix(trimmed, collectorTokenV2Prefix) {
		return parseSignedCollectorToken(trimmed, fallbackBaseURL)
	}

	return nil, ErrCollectorTokenInvalid
}

func parseSignedCollectorToken(raw, fallbackBaseURL string) (*collectorTokenPayload, error) {
	encoded := strings.TrimPrefix(strings.TrimSpace(raw), collectorTokenV2Prefix)
	encodedPayload, encodedSignature, ok := strings.Cut(encoded, onboardingTokenSignatureSep)
	if !ok || encodedPayload == "" || encodedSignature == "" {
		return nil, ErrCollectorTokenInvalid
	}

	data, err := base64.RawURLEncoding.DecodeString(encodedPayload)
	if err != nil {
		return nil, ErrCollectorTokenInvalid
	}

	signature, err := base64.RawURLEncoding.DecodeString(encodedSignature)
	if err != nil {
		return nil, ErrCollectorTokenInvalid
	}

	publicKey, err := onboardingTokenPublicKey()
	if err != nil {
		return nil, err
	}

	if !ed25519.Verify(publicKey, data, signature) {
		return nil, ErrOnboardingTokenInvalidSignature
	}

	var payload collectorTokenPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, ErrCollectorTokenInvalid
	}

	payload.BaseURL = strings.TrimSpace(payload.BaseURL)
	payload.PackageID = strings.TrimSpace(payload.PackageID)
	payload.Secret = strings.TrimSpace(payload.Secret)
	payload.ConfigFile = strings.TrimSpace(payload.ConfigFile)

	if payload.PackageID == "" || payload.Secret == "" {
		return nil, ErrCollectorTokenInvalid
	}

	if payload.BaseURL == "" {
		payload.BaseURL = strings.TrimSpace(fallbackBaseURL)
	}

	normalizedBaseURL, err := normalizeBaseURL(payload.BaseURL)
	if err != nil {
		return nil, err
	}
	payload.BaseURL = normalizedBaseURL

	if payload.ExpiresAt != nil && time.Now().Unix() > *payload.ExpiresAt {
		return nil, ErrCollectorTokenExpired
	}

	return &payload, nil
}

func extractCollectorBundle(data []byte) (string, error) {
	tempDir, err := os.MkdirTemp("", "serviceradar-collector-*")
	if err != nil {
		return "", fmt.Errorf("create temp dir: %w", err)
	}

	reader := bytes.NewReader(data)
	gzr, err := gzip.NewReader(reader)
	if err != nil {
		_ = os.RemoveAll(tempDir)
		return "", fmt.Errorf("open bundle gzip: %w", err)
	}
	defer func() { _ = gzr.Close() }()

	tr := tar.NewReader(gzr)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			_ = os.RemoveAll(tempDir)
			return "", fmt.Errorf("read bundle tar: %w", err)
		}
		if hdr == nil {
			continue
		}
		if invalidArchivePath(hdr.Name) {
			_ = os.RemoveAll(tempDir)
			return "", ErrCollectorBundleIncomplete
		}

		target, err := safeBundlePath(tempDir, hdr.Name)
		if err != nil {
			_ = os.RemoveAll(tempDir)
			return "", err
		}
		if hdr.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0755); err != nil {
				_ = os.RemoveAll(tempDir)
				return "", fmt.Errorf("create dir: %w", err)
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			_ = os.RemoveAll(tempDir)
			return "", fmt.Errorf("create dir: %w", err)
		}

		file, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			_ = os.RemoveAll(tempDir)
			return "", fmt.Errorf("create file: %w", err)
		}

		if _, err := io.Copy(file, tr); err != nil {
			_ = file.Close()
			_ = os.RemoveAll(tempDir)
			return "", fmt.Errorf("write file: %w", err)
		}
		_ = file.Close()
	}

	return tempDir, nil
}

func findBundleRoot(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", fmt.Errorf("read bundle dir: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			return filepath.Join(dir, entry.Name()), nil
		}
	}

	return "", ErrCollectorBundleIncomplete
}

func selectCollectorConfig(configDir, preferred string) (string, error) {
	if preferred != "" {
		if fileExists(filepath.Join(configDir, preferred)) {
			return preferred, nil
		}
		return "", ErrCollectorBundleIncomplete
	}

	entries, err := os.ReadDir(configDir)
	if err != nil {
		return "", ErrCollectorBundleIncomplete
	}

	var files []string
	for _, entry := range entries {
		if !entry.IsDir() {
			files = append(files, entry.Name())
		}
	}

	if len(files) == 0 {
		return "", ErrCollectorBundleIncomplete
	}

	sort.Strings(files)
	return files[0], nil
}

func copyFileAtomic(src, dest string, mode os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("read %s: %w", src, err)
	}
	if err := writeFileAtomic(dest, data, mode); err != nil {
		return fmt.Errorf("write %s: %w", dest, err)
	}
	return nil
}

func anyFileExists(dir string, names ...string) bool {
	for _, name := range names {
		if fileExists(filepath.Join(dir, name)) {
			return true
		}
	}
	return false
}

func defaultIfEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return strings.TrimSpace(value)
}

func safeBundlePath(root, name string) (string, error) {
	cleaned := path.Clean(name)
	if cleaned == "." {
		cleaned = ""
	}
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.HasPrefix(cleaned, "/") {
		return "", ErrCollectorBundleIncomplete
	}

	target := filepath.Join(root, filepath.FromSlash(cleaned))
	if target == root || strings.HasPrefix(target, root+string(os.PathSeparator)) {
		return target, nil
	}

	return "", ErrCollectorBundleIncomplete
}

func invalidArchivePath(name string) bool {
	cleaned := path.Clean(name)
	if cleaned == "." {
		cleaned = ""
	}
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") || strings.HasPrefix(cleaned, "/") {
		return true
	}
	if strings.Contains(cleaned, "..") {
		return true
	}
	return false
}
