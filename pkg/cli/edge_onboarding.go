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
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
)

const (
	outputFormatText = "text"
	outputFormatJSON = "json"

	edgePackageFormatTar  = "tar"
	edgePackageFormatJSON = "json"
)

type edgePackageView struct {
	PackageID          string     `json:"package_id"`
	Label              string     `json:"label"`
	ComponentID        string     `json:"component_id"`
	ComponentType      string     `json:"component_type"`
	ParentType         string     `json:"parent_type,omitempty"`
	ParentID           string     `json:"parent_id,omitempty"`
	PollerID           string     `json:"poller_id"`
	Site               string     `json:"site,omitempty"`
	Status             string     `json:"status"`
	DownstreamSPIFFEID string     `json:"downstream_spiffe_id"`
	Selectors          []string   `json:"selectors,omitempty"`
	JoinTokenExpiresAt time.Time  `json:"join_token_expires_at"`
	DownloadExpiresAt  time.Time  `json:"download_token_expires_at"`
	CreatedBy          string     `json:"created_by"`
	CreatedAt          time.Time  `json:"created_at"`
	UpdatedAt          time.Time  `json:"updated_at"`
	DeliveredAt        *time.Time `json:"delivered_at,omitempty"`
	ActivatedAt        *time.Time `json:"activated_at,omitempty"`
	ActivatedFromIP    *string    `json:"activated_from_ip,omitempty"`
	LastSeenSPIFFEID   *string    `json:"last_seen_spiffe_id,omitempty"`
	RevokedAt          *time.Time `json:"revoked_at,omitempty"`
	DeletedAt          *time.Time `json:"deleted_at,omitempty"`
	DeletedBy          string     `json:"deleted_by,omitempty"`
	DeletedReason      string     `json:"deleted_reason,omitempty"`
	MetadataJSON       string     `json:"metadata_json,omitempty"`
	CheckerKind        string     `json:"checker_kind,omitempty"`
	CheckerConfigJSON  string     `json:"checker_config_json,omitempty"`
	KVRevision         uint64     `json:"kv_revision,omitempty"`
	Notes              string     `json:"notes,omitempty"`
}

type edgePackageCreateAPIResponse struct {
	Package       edgePackageView `json:"package"`
	JoinToken     string          `json:"join_token"`
	DownloadToken string          `json:"download_token"`
	BundlePEM     string          `json:"bundle_pem"`
}

type edgePackageDeliverAPIResponse struct {
	Package   edgePackageView `json:"package"`
	JoinToken string          `json:"join_token"`
	BundlePEM string          `json:"bundle_pem"`
}

type edgePackageRevokeAPIResponse struct {
	PackageID string    `json:"package_id"`
	Status    string    `json:"status"`
	PollerID  string    `json:"poller_id"`
	UpdatedAt time.Time `json:"updated_at"`
	RevokedAt time.Time `json:"revoked_at"`
}

// RunEdgeCommand dispatches multi-level `edge ...` invocations.
func RunEdgeCommand(cfg *CmdConfig) error {
	switch cfg.EdgeCommand {
	case "package":
		return runEdgePackageCommand(cfg)
	default:
		return fmt.Errorf("unknown edge resource %q", cfg.EdgeCommand)
	}
}

func runEdgePackageCommand(cfg *CmdConfig) error {
	switch cfg.EdgePackageAction {
	case "create":
		return RunEdgePackageCreate(cfg)
	case "list":
		return RunEdgePackageList(cfg)
	case "show":
		return RunEdgePackageShow(cfg)
	case "download":
		return RunEdgePackageDownload(cfg)
	case "revoke":
		return RunEdgePackageRevoke(cfg)
	case "token":
		return RunEdgePackageToken(cfg)
	default:
		return fmt.Errorf("unknown edge package action %q", cfg.EdgePackageAction)
	}
}

// RunEdgePackageCreate provisions a new onboarding package via the Core API.
func RunEdgePackageCreate(cfg *CmdConfig) error {
	if strings.TrimSpace(cfg.EdgePackageLabel) == "" {
		return errEdgePackageLabel
	}

	outputFormat, err := normalizeOutputFormat(cfg.EdgeOutputFormat)
	if err != nil {
		return err
	}

	componentType, err := normalizeComponentType(cfg.EdgePackageComponentType)
	if err != nil {
		return err
	}

	parentType := strings.TrimSpace(cfg.EdgePackageParentType)
	if parentType != "" {
		if _, err := normalizeComponentType(parentType); err != nil {
			return fmt.Errorf("invalid parent-type: %w", err)
		}
	}

	coreURL := normaliseCoreURL(cfg.CoreAPIURL)
	cfg.CoreAPIURL = coreURL

	payload := map[string]interface{}{
		"label":          strings.TrimSpace(cfg.EdgePackageLabel),
		"component_type": componentType,
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageComponentID); trimmed != "" {
		payload["component_id"] = trimmed
	}
	if parentType != "" {
		payload["parent_type"] = parentType
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageParentID); trimmed != "" {
		payload["parent_id"] = trimmed
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackagePollerID); trimmed != "" {
		payload["poller_id"] = trimmed
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageSite); trimmed != "" {
		payload["site"] = trimmed
	}
	if len(cfg.EdgePackageSelectors) > 0 {
		payload["selectors"] = trimValues(cfg.EdgePackageSelectors)
	}
	if cfg.EdgePackageMetadata != "" {
		payload["metadata_json"] = cfg.EdgePackageMetadata
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageCheckerKind); trimmed != "" {
		payload["checker_kind"] = trimmed
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageCheckerConfig); trimmed != "" {
		payload["checker_config_json"] = trimmed
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageNotes); trimmed != "" {
		payload["notes"] = trimmed
	}
	if cfg.EdgeJoinTTLSeconds > 0 {
		payload["join_token_ttl_seconds"] = cfg.EdgeJoinTTLSeconds
	}
	if cfg.EdgeDownloadTTLSeconds > 0 {
		payload["download_token_ttl_seconds"] = cfg.EdgeDownloadTTLSeconds
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageDownstreamID); trimmed != "" {
		payload["downstream_spiffe_id"] = trimmed
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageDataSvc); trimmed != "" {
		payload["datasvc_endpoint"] = trimmed
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint := fmt.Sprintf("%s/api/admin/edge-packages", coreURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create package request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request edge package create: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusCreated {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var result edgePackageCreateAPIResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode create response: %w", err)
	}

	token, err := edgeonboarding.EncodeToken(result.Package.PackageID, result.DownloadToken, cfg.CoreAPIURL)
	if err != nil {
		return fmt.Errorf("encode onboarding token: %w", err)
	}

	switch outputFormat {
	case outputFormatJSON:
		payload := map[string]interface{}{
			"package":          result.Package,
			"join_token":       result.JoinToken,
			"download_token":   result.DownloadToken,
			"bundle_pem":       result.BundlePEM,
			"onboarding_token": token,
			"core_api_url":     cfg.CoreAPIURL,
		}
		data, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			return fmt.Errorf("encode output: %w", err)
		}
		fmt.Println(string(data))
	default:
		printCreateResult(result, token, cfg.EdgePackageDataSvc)
	}

	return nil
}

// RunEdgePackageList retrieves package summaries from the Core API.
func RunEdgePackageList(cfg *CmdConfig) error {
	outputFormat, err := normalizeOutputFormat(cfg.EdgeOutputFormat)
	if err != nil {
		return err
	}

	coreURL := normaliseCoreURL(cfg.CoreAPIURL)
	cfg.CoreAPIURL = coreURL

	params := url.Values{}
	if cfg.EdgePackageLimit > 0 {
		params.Set("limit", strconv.Itoa(cfg.EdgePackageLimit))
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackagePollerFilter); trimmed != "" {
		params.Set("poller_id", trimmed)
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageParentFilter); trimmed != "" {
		params.Set("parent_id", trimmed)
	}
	if trimmed := strings.TrimSpace(cfg.EdgePackageComponentFilter); trimmed != "" {
		params.Set("component_id", trimmed)
	}
	for _, status := range cfg.EdgePackageStatuses {
		if trimmed := strings.TrimSpace(status); trimmed != "" {
			params.Add("status", trimmed)
		}
	}
	for _, typ := range cfg.EdgePackageTypes {
		if trimmed := strings.TrimSpace(typ); trimmed != "" {
			params.Add("component_type", trimmed)
		}
	}

	endpoint := fmt.Sprintf("%s/api/admin/edge-packages", coreURL)
	if encoded := params.Encode(); encoded != "" {
		endpoint = endpoint + "?" + encoded
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create list request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request edge package list: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var packages []edgePackageView
	if err := json.NewDecoder(resp.Body).Decode(&packages); err != nil {
		return fmt.Errorf("decode list response: %w", err)
	}

	switch outputFormat {
	case outputFormatJSON:
		data, err := json.MarshalIndent(packages, "", "  ")
		if err != nil {
			return fmt.Errorf("encode output: %w", err)
		}
		fmt.Println(string(data))
	default:
		printPackageTable(packages)
	}

	return nil
}

// RunEdgePackageShow fetches a single package record.
func RunEdgePackageShow(cfg *CmdConfig) error {
	if strings.TrimSpace(cfg.EdgePackageID) == "" {
		return errEdgePackageID
	}
	outputFormat, err := normalizeOutputFormat(cfg.EdgeOutputFormat)
	if err != nil {
		return err
	}

	coreURL := normaliseCoreURL(cfg.CoreAPIURL)
	cfg.CoreAPIURL = coreURL

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint, err := url.JoinPath(coreURL, "/api/admin/edge-packages", cfg.EdgePackageID)
	if err != nil {
		return fmt.Errorf("build show endpoint: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create show request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request edge package show: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var pkg edgePackageView
	if err := json.NewDecoder(resp.Body).Decode(&pkg); err != nil {
		return fmt.Errorf("decode package response: %w", err)
	}

	switch outputFormat {
	case outputFormatJSON:
		data, err := json.MarshalIndent(pkg, "", "  ")
		if err != nil {
			return fmt.Errorf("encode output: %w", err)
		}
		fmt.Println(string(data))
	default:
		printPackageDetails(pkg)
	}

	if cfg.EdgePackageReissueToken {
		if strings.TrimSpace(cfg.EdgePackageDownloadToken) == "" {
			return errDownloadToken
		}
		token, err := edgeonboarding.EncodeToken(pkg.PackageID, cfg.EdgePackageDownloadToken, cfg.CoreAPIURL)
		if err != nil {
			return fmt.Errorf("encode onboarding token: %w", err)
		}
		fmt.Printf("\nONBOARDING_TOKEN=%s\n", token)
	}

	return nil
}

// RunEdgePackageDownload calls the admin API to retrieve onboarding artifacts.
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

	format, err := normalizePackageFormat(cfg.EdgePackageFormat)
	if err != nil {
		return err
	}

	baseURL := normaliseCoreURL(cfg.CoreAPIURL)
	cfg.CoreAPIURL = baseURL
	endpoint, err := url.JoinPath(baseURL, "/api/admin/edge-packages", cfg.EdgePackageID, "download")
	if err != nil {
		return fmt.Errorf("build download endpoint: %w", err)
	}
	if format == edgePackageFormatJSON {
		endpoint = endpoint + "?format=json"
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
	if format == edgePackageFormatJSON {
		req.Header.Set("Accept", "application/json")
	} else {
		req.Header.Set("Accept", "application/gzip")
	}
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

	if format == edgePackageFormatJSON {
		var deliver edgePackageDeliverAPIResponse
		if err := json.NewDecoder(resp.Body).Decode(&deliver); err != nil {
			return fmt.Errorf("decode JSON download: %w", err)
		}
		token, err := edgeonboarding.EncodeToken(deliver.Package.PackageID, cfg.EdgePackageDownloadToken, cfg.CoreAPIURL)
		if err != nil {
			return fmt.Errorf("encode onboarding token: %w", err)
		}
		payload := map[string]interface{}{
			"package":          deliver.Package,
			"join_token":       deliver.JoinToken,
			"bundle_pem":       deliver.BundlePEM,
			"onboarding_token": token,
			"core_api_url":     cfg.CoreAPIURL,
		}
		data, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			return fmt.Errorf("encode download payload: %w", err)
		}
		return writeJSONOutput(data, cfg.EdgePackageOutput)
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

// RunEdgePackageToken emits an edgepkg-v1 token for use as ONBOARDING_TOKEN.
func RunEdgePackageToken(cfg *CmdConfig) error {
	if strings.TrimSpace(cfg.EdgePackageID) == "" {
		return errEdgePackageID
	}
	if strings.TrimSpace(cfg.EdgePackageDownloadToken) == "" {
		return errDownloadToken
	}

	token, err := edgeonboarding.EncodeToken(cfg.EdgePackageID, cfg.EdgePackageDownloadToken, cfg.CoreAPIURL)
	if err != nil {
		return fmt.Errorf("encode onboarding token: %w", err)
	}

	fmt.Println(token)
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

func printCreateResult(result edgePackageCreateAPIResponse, token, datasvc string) {
	fmt.Printf("Package %s (%s) created\n", result.Package.PackageID, result.Package.ComponentType)
	if result.Package.Label != "" {
		fmt.Printf("Label        : %s\n", result.Package.Label)
	}
	if result.Package.ComponentID != "" {
		fmt.Printf("Component ID : %s\n", result.Package.ComponentID)
	}
	if result.Package.PollerID != "" {
		fmt.Printf("Poller ID    : %s\n", result.Package.PollerID)
	}
	if result.Package.Site != "" {
		fmt.Printf("Site         : %s\n", result.Package.Site)
	}
	fmt.Printf("Status       : %s\n", result.Package.Status)
	fmt.Printf("Join token   : %s\n", result.JoinToken)
	fmt.Printf("Download token: %s\n", result.DownloadToken)
	if datasvc != "" {
		fmt.Printf("Datasvc endpoint: %s\n", datasvc)
	}
	fmt.Printf("ONBOARDING_TOKEN=%s\n", token)
}

func printPackageTable(packages []edgePackageView) {
	if len(packages) == 0 {
		fmt.Println("No edge packages found.")
		return
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "PACKAGE\tCOMPONENT\tSTATUS\tDOWNLOAD EXPIRES\tLABEL")
	for _, pkg := range packages {
		fmt.Fprintf(
			w,
			"%s\t%s\t%s\t%s\t%s\n",
			pkg.PackageID,
			pkg.ComponentType,
			pkg.Status,
			formatTimestamp(pkg.DownloadExpiresAt),
			pkg.Label,
		)
	}
	_ = w.Flush()
}

func printPackageDetails(pkg edgePackageView) {
	fmt.Printf("Package ID : %s\n", pkg.PackageID)
	if pkg.Label != "" {
		fmt.Printf("Label      : %s\n", pkg.Label)
	}
	fmt.Printf("Component  : %s\n", pkg.ComponentType)
	if pkg.ComponentID != "" {
		fmt.Printf("Component ID: %s\n", pkg.ComponentID)
	}
	if pkg.ParentID != "" {
		fmt.Printf("Parent     : %s (%s)\n", pkg.ParentID, pkg.ParentType)
	}
	if pkg.PollerID != "" {
		fmt.Printf("Poller ID  : %s\n", pkg.PollerID)
	}
	if pkg.Site != "" {
		fmt.Printf("Site       : %s\n", pkg.Site)
	}
	fmt.Printf("Status     : %s\n", pkg.Status)
	fmt.Printf("Created    : %s by %s\n", formatTimestamp(pkg.CreatedAt), pkg.CreatedBy)
	fmt.Printf("Updated    : %s\n", formatTimestamp(pkg.UpdatedAt))
	fmt.Printf("Join token expires    : %s\n", formatTimestamp(pkg.JoinTokenExpiresAt))
	fmt.Printf("Download token expires: %s\n", formatTimestamp(pkg.DownloadExpiresAt))
	if pkg.DownstreamSPIFFEID != "" {
		fmt.Printf("SPIFFE ID  : %s\n", pkg.DownstreamSPIFFEID)
	}
	if len(pkg.Selectors) > 0 {
		fmt.Printf("Selectors  : %s\n", strings.Join(pkg.Selectors, ", "))
	}
	if pkg.Notes != "" {
		fmt.Printf("Notes      : %s\n", pkg.Notes)
	}
	if pkg.MetadataJSON != "" {
		fmt.Printf("Metadata JSON: %s\n", pkg.MetadataJSON)
	}
	if ts := formatOptionalTime(pkg.DeliveredAt); ts != "" {
		fmt.Printf("Delivered  : %s\n", ts)
	}
	if ts := formatOptionalTime(pkg.ActivatedAt); ts != "" {
		fmt.Printf("Activated  : %s\n", ts)
	}
	if ts := formatOptionalTime(pkg.RevokedAt); ts != "" {
		fmt.Printf("Revoked    : %s\n", ts)
	}
}

func formatTimestamp(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.UTC().Format(time.RFC3339)
}

func formatOptionalTime(t *time.Time) string {
	if t == nil || t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func trimValues(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func normalizeOutputFormat(raw string) (string, error) {
	format := strings.ToLower(strings.TrimSpace(raw))
	if format == "" || format == outputFormatText {
		return outputFormatText, nil
	}
	if format == outputFormatJSON {
		return outputFormatJSON, nil
	}
	return "", errInvalidOutputFormat
}

func normalizePackageFormat(raw string) (string, error) {
	format := strings.ToLower(strings.TrimSpace(raw))
	if format == "" || format == edgePackageFormatTar {
		return edgePackageFormatTar, nil
	}
	if format == edgePackageFormatJSON {
		return edgePackageFormatJSON, nil
	}
	return "", errInvalidPackageFormat
}

func normalizeComponentType(raw string) (string, error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	if value == "" {
		value = "poller"
	}
	switch value {
	case "poller", "agent", "checker":
		return value, nil
	default:
		return "", fmt.Errorf("unknown component type %q", raw)
	}
}

func writeJSONOutput(data []byte, outputPath string) error {
	if strings.TrimSpace(outputPath) == "" {
		fmt.Println(string(data))
		return nil
	}
	dir := filepath.Dir(outputPath)
	if dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil && !os.IsExist(err) {
			return fmt.Errorf("create output directory: %w", err)
		}
	}
	if err := os.WriteFile(outputPath, data, 0o600); err != nil {
		return fmt.Errorf("write %s: %w", outputPath, err)
	}
	fmt.Printf("Wrote %s\n", outputPath)
	return nil
}
