package cli

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type edgePackageRevokeAPIResponse struct {
	PackageID string    `json:"package_id"`
	Status    string    `json:"status"`
	PollerID  string    `json:"poller_id"`
	UpdatedAt time.Time `json:"updated_at"`
	RevokedAt time.Time `json:"revoked_at"`
}

// RunEdgePackageDownload calls the admin API to retrieve onboarding artefacts.
func RunEdgePackageDownload(cfg *CmdConfig) error {
	if cfg.CoreAPIURL == "" {
		return errCoreURLRequired
	}
	if strings.TrimSpace(cfg.EdgePackageID) == "" {
		return errEdgePackageID
	}
	if strings.TrimSpace(cfg.EdgePackageDownloadToken) == "" {
		return errDownloadToken
	}

	baseURL := normaliseCoreURL(cfg.CoreAPIURL)
	endpoint, err := url.JoinPath(baseURL, "/api/admin/edge-packages", cfg.EdgePackageID, "download")
	if err != nil {
		return fmt.Errorf("build download endpoint: %w", err)
	}

	payload := map[string]string{
		"download_token": strings.TrimSpace(cfg.EdgePackageDownloadToken),
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode download payload: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create download request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/gzip")
	applyAuthHeaders(req, cfg)

	client := newHTTPClient(cfg.TLSSkipVerify)

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("request edge package download: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		text := strings.TrimSpace(string(message))
		if text == "" {
			text = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, text)
	}

	if ct := strings.TrimSpace(resp.Header.Get("Content-Type")); ct != "" && !strings.Contains(ct, "gzip") {
		return fmt.Errorf("%w: unexpected content type %q", errCoreAPIError, ct)
	}

	outputPath := strings.TrimSpace(cfg.EdgePackageOutput)
	if outputPath == "" {
		fallback := fmt.Sprintf("edge-package-%s.tar.gz", strings.TrimSpace(cfg.EdgePackageID))
		if strings.TrimSpace(cfg.EdgePackageID) == "" {
			fallback = "edge-package.tar.gz"
		}
		outputPath = suggestEdgePackageFilename(resp.Header.Get("Content-Disposition"), fallback)
	}

	if dir := filepath.Dir(outputPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil && !os.IsExist(err) {
			return fmt.Errorf("prepare output directory: %w", err)
		}
	}

	file, err := os.OpenFile(outputPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("create %s: %w", outputPath, err)
	}
	if _, err := io.Copy(file, resp.Body); err != nil {
		_ = file.Close()
		return fmt.Errorf("write archive to %s: %w", outputPath, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close %s: %w", outputPath, err)
	}

	packageID := strings.TrimSpace(resp.Header.Get("X-Edge-Package-ID"))
	if packageID == "" {
		packageID = strings.TrimSpace(cfg.EdgePackageID)
	}
	pollerID := strings.TrimSpace(resp.Header.Get("X-Edge-Poller-ID"))
	if pollerID != "" {
		fmt.Printf("Wrote onboarding archive to %s (package %s, poller %s)\n", outputPath, packageID, pollerID)
	} else {
		fmt.Printf("Wrote onboarding archive to %s (package %s)\n", outputPath, packageID)
	}

	return nil
}

// RunEdgePackageRevoke calls the admin API to revoke an onboarding package.
func RunEdgePackageRevoke(cfg *CmdConfig) error {
	if cfg.CoreAPIURL == "" {
		return errCoreURLRequired
	}
	if strings.TrimSpace(cfg.EdgePackageID) == "" {
		return errEdgePackageID
	}

	baseURL := normaliseCoreURL(cfg.CoreAPIURL)
	endpoint, err := url.JoinPath(baseURL, "/api/admin/edge-packages", cfg.EdgePackageID, "revoke")
	if err != nil {
		return fmt.Errorf("build revoke endpoint: %w", err)
	}

	payload := map[string]string{}
	if reason := strings.TrimSpace(cfg.EdgePackageReason); reason != "" {
		payload["reason"] = reason
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode revoke payload: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create revoke request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	applyAuthHeaders(req, cfg)

	client := newHTTPClient(cfg.TLSSkipVerify)

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("request edge package revoke: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		text := strings.TrimSpace(string(message))
		if text == "" {
			text = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, text)
	}

	var result edgePackageRevokeAPIResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode revoke response: %w", err)
	}

	fmt.Printf("Package %s revoked (status: %s)\n", result.PackageID, result.Status)

	return nil
}

func normaliseCoreURL(raw string) string {
	base := strings.TrimSpace(raw)
	if base == "" {
		return defaultCoreURL
	}
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		return "https://" + base
	}
	return base
}

func applyAuthHeaders(req *http.Request, cfg *CmdConfig) {
	if cfg == nil {
		return
	}
	if strings.TrimSpace(cfg.BearerToken) != "" {
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(cfg.BearerToken))
	}
	if strings.TrimSpace(cfg.APIKey) != "" {
		req.Header.Set("X-API-Key", strings.TrimSpace(cfg.APIKey))
	}
}

func newHTTPClient(skipVerify bool) *http.Client {
	client := &http.Client{Timeout: 15 * time.Second}
	if skipVerify {
		if transport, ok := http.DefaultTransport.(*http.Transport); ok {
			clone := transport.Clone()
			if clone.TLSClientConfig == nil {
				clone.TLSClientConfig = &tls.Config{}
			}
			clone.TLSClientConfig.InsecureSkipVerify = true //nolint:gosec // intentional for CLI flag
			client.Transport = clone
		}
	}
	return client
}

func suggestEdgePackageFilename(disposition, fallback string) string {
	if filename := parseDispositionFilename(disposition); filename != "" {
		return filepath.Base(filename)
	}
	fallback = strings.TrimSpace(fallback)
	if fallback == "" {
		return "edge-package.tar.gz"
	}
	return fallback
}

func parseDispositionFilename(header string) string {
	if strings.TrimSpace(header) == "" {
		return ""
	}
	_, params, err := mime.ParseMediaType(header)
	if err != nil {
		return ""
	}
	if filename, ok := params["filename"]; ok {
		return filename
	}
	return ""
}
