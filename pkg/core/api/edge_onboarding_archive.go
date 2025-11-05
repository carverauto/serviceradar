package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/spiffeid"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	edgePackageDefaultFilename = "edge-package.tar.gz"
	defaultInsecureBootstrap   = "false"
)

var (
	errEdgePackageArchive      = errors.New("edge onboarding: archive build failed")
	errEdgePackageMissing      = errors.New("edge onboarding: package missing from deliver result")
	errEdgeMetadataMissingKey  = errors.New("edge onboarding: missing metadata key")
	errEdgeTrustDomainMetadata = errors.New("edge onboarding: missing trust domain metadata and unable to derive")
)

// buildEdgePackageArchive packages the sensitive onboarding artifacts into a tar.gz bundle.
// It returns the archive bytes and the suggested filename.
func buildEdgePackageArchive(result *models.EdgeOnboardingDeliverResult, now time.Time) ([]byte, string, error) {
	if result == nil || result.Package == nil {
		return nil, "", fmt.Errorf("%w: package payload missing", errEdgePackageArchive)
	}

	meta := parseEdgeMetadata(result.Package.MetadataJSON)

	name := strings.TrimSpace(result.Package.PollerID)
	if name == "" {
		name = "edge-poller"
	}
	filename := sanitizeArchiveName(fmt.Sprintf("edge-package-%s.tar.gz", name))

	envContent, err := renderEdgeEnvFile(result, meta)
	if err != nil {
		return nil, "", fmt.Errorf("%w: %w", errEdgePackageArchive, err)
	}

	readmeContent := renderEdgeReadme(result, meta)
	metadataJSON, err := renderEdgeMetadataJSON(result.Package, meta, now)
	if err != nil {
		return nil, "", fmt.Errorf("%w: %w", errEdgePackageArchive, err)
	}

	buffer := bytes.NewBuffer(nil)
	gzw := gzip.NewWriter(buffer)
	tw := tar.NewWriter(gzw)

	write := func(name string, mode int64, body []byte) error {
		hdr := &tar.Header{
			Name:    name,
			Mode:    mode,
			Size:    int64(len(body)),
			ModTime: now,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if len(body) == 0 {
			return nil
		}
		_, err := tw.Write(body)
		return err
	}

	if err := writeDirectory(tw, "spire", now); err != nil {
		return nil, "", fmt.Errorf("%w: %w", errEdgePackageArchive, err)
	}

	files := []struct {
		Name string
		Mode int64
		Body []byte
	}{
		{"README.txt", 0o600, readmeContent},
		{"metadata.json", 0o600, metadataJSON},
		{"edge-poller.env", 0o600, envContent},
		{"spire/upstream-join-token", 0o600, append([]byte(result.JoinToken), '\n')},
		{"spire/upstream-bundle.pem", 0o600, ensureTrailingNewline(result.BundlePEM)},
	}

	for _, file := range files {
		if err := write(file.Name, file.Mode, file.Body); err != nil {
			return nil, "", fmt.Errorf("%w: write %s: %w", errEdgePackageArchive, file.Name, err)
		}
	}

	if err := tw.Close(); err != nil {
		return nil, "", fmt.Errorf("%w: %w", errEdgePackageArchive, err)
	}
	if err := gzw.Close(); err != nil {
		return nil, "", fmt.Errorf("%w: %w", errEdgePackageArchive, err)
	}

	return buffer.Bytes(), filename, nil
}

func writeDirectory(tw *tar.Writer, dir string, modTime time.Time) error {
	dir = path.Clean(dir)
	if dir == "." || dir == "/" {
		return nil
	}
	hdr := &tar.Header{
		Name:     dir + "/",
		Mode:     0o755,
		Typeflag: tar.TypeDir,
		ModTime:  modTime,
	}
	return tw.WriteHeader(hdr)
}

func ensureTrailingNewline(data []byte) []byte {
	if len(data) == 0 {
		return []byte{}
	}
	if data[len(data)-1] == '\n' {
		return data
	}
	return append(append([]byte(nil), data...), '\n')
}

func sanitizeArchiveName(raw string) string {
	if raw == "" {
		return edgePackageDefaultFilename
	}
	base, params, err := mime.ParseMediaType(fmt.Sprintf("attachment; filename=%q", raw))
	if err == nil {
		_ = base
		if fn := params["filename"]; fn != "" {
			raw = fn
		}
	}
	raw = strings.ReplaceAll(raw, "..", "")
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return edgePackageDefaultFilename
	}
	return raw
}

func parseEdgeMetadata(raw string) map[string]string {
	result := make(map[string]string)
	if strings.TrimSpace(raw) == "" {
		return result
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return result
	}

	for key, value := range decoded {
		normalised := strings.ToLower(strings.TrimSpace(key))
		if normalised == "" || value == nil {
			continue
		}

		switch v := value.(type) {
		case string:
			if strings.TrimSpace(v) != "" {
				result[normalised] = v
			}
		case bool:
			result[normalised] = strconv.FormatBool(v)
		case float64:
			result[normalised] = strconv.FormatFloat(v, 'f', -1, 64)
		default:
			if encoded, err := json.Marshal(v); err == nil {
				result[normalised] = string(encoded)
			}
		}
	}

	return result
}

func renderEdgeEnvFile(result *models.EdgeOnboardingDeliverResult, meta map[string]string) ([]byte, error) {
	cfg := result.Package
	if cfg == nil {
		return nil, errEdgePackageMissing
	}

	get := func(keys ...string) string {
		for _, key := range keys {
			if value, ok := meta[strings.ToLower(key)]; ok && strings.TrimSpace(value) != "" {
				return strings.TrimSpace(value)
			}
		}
		return ""
	}

	trustDomain := get("trust_domain")
	if trustDomain == "" && cfg.DownstreamSPIFFEID != "" {
		if id, err := spiffeid.FromString(cfg.DownstreamSPIFFEID); err == nil {
			trustDomain = id.TrustDomain().Name()
		}
	}

	coreAddress := get("core_address")
	if coreAddress == "" {
		return nil, fmt.Errorf("%w: %q", errEdgeMetadataMissingKey, "core_address")
	}

	coreSPIFFE := get("core_spiffe_id")
	if coreSPIFFE == "" {
		return nil, fmt.Errorf("%w: %q", errEdgeMetadataMissingKey, "core_spiffe_id")
	}

	upstreamAddress := get("spire_upstream_address", "upstream_address")
	if upstreamAddress == "" {
		return nil, fmt.Errorf("%w: %q", errEdgeMetadataMissingKey, "spire_upstream_address")
	}

	upstreamPort := get("spire_upstream_port", "upstream_port")
	if upstreamPort == "" {
		upstreamPort = "18081"
	}

	parentID := get("spire_parent_id", "parent_spiffe_id")
	if parentID == "" {
		return nil, fmt.Errorf("%w: %q", errEdgeMetadataMissingKey, "spire_parent_id")
	}

	agentAddress := get("agent_address")
	if agentAddress == "" {
		agentAddress = "agent:50051"
	}

	agentSPIFFE := get("agent_spiffe_id")
	if agentSPIFFE == "" {
		return nil, fmt.Errorf("%w: %q", errEdgeMetadataMissingKey, "agent_spiffe_id")
	}

	waitAttempts := get("nested_spire_wait_attempts")
	if waitAttempts == "" {
		waitAttempts = "120"
	}

	logLevel := get("log_level")
	if logLevel == "" {
		logLevel = "info"
	}

	logsDir := get("logs_dir")
	if logsDir == "" {
		logsDir = "./logs"
	}

	nestedAssets := get("nested_spire_assets")
	if nestedAssets == "" {
		nestedAssets = "./spire"
	}

	templateDir := get("serviceradar_templates")
	if templateDir == "" {
		templateDir = "./packaging/core/config"
	}

	insecureBootstrap := get("spire_insecure_bootstrap")
	if insecureBootstrap == "" {
		insecureBootstrap = defaultInsecureBootstrap
	}

	if trustDomain == "" {
		return nil, errEdgeTrustDomainMetadata
	}

	env := map[string]string{
		"POLLERS_SECURITY_MODE":              "spiffe",
		"POLLERS_TRUST_DOMAIN":               trustDomain,
		"POLLERS_SPIRE_UPSTREAM_ADDRESS":     upstreamAddress,
		"POLLERS_SPIRE_UPSTREAM_PORT":        upstreamPort,
		"POLLERS_SPIRE_INSECURE_BOOTSTRAP":   insecureBootstrap,
		"POLLERS_SPIRE_PARENT_ID":            parentID,
		"POLLERS_SPIRE_DOWNSTREAM_SPIFFE_ID": cfg.DownstreamSPIFFEID,
		"NESTED_SPIRE_PARENT_ID":             parentID,
		"NESTED_SPIRE_DOWNSTREAM_SPIFFE_ID":  cfg.DownstreamSPIFFEID,
		"NESTED_SPIRE_AGENT_SPIFFE_ID":       agentSPIFFE,
		"MANAGE_NESTED_SPIRE":                "enabled",
		"ENABLE_POLLER_JOIN_TOKEN":           "enabled",
		"DOWNSTREAM_REGISTRATION_MODE":       "disabled",
		"NESTED_SPIRE_WAIT_ATTEMPTS":         waitAttempts,
		"LOG_LEVEL":                          logLevel,
		"LOGS_DIR":                           logsDir,
		"NESTED_SPIRE_ASSETS":                nestedAssets,
		"SERVICERADAR_TEMPLATES":             templateDir,
		"CORE_ADDRESS":                       coreAddress,
		"CORE_SPIFFE_ID":                     coreSPIFFE,
		"POLLERS_AGENT_ADDRESS":              agentAddress,
		"AGENT_SPIFFE_ID":                    agentSPIFFE,
		"EDGE_PACKAGE_ID":                    cfg.PackageID,
	}

	if kvAddr := get("kv_address"); kvAddr != "" {
		env["KV_ADDRESS"] = kvAddr
		if kvSPIFFE := get("kv_spiffe_id"); kvSPIFFE != "" {
			env["KV_SPIFFE_ID"] = kvSPIFFE
		}
	}

	keys := make([]string, 0, len(env))
	for key := range env {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var builder strings.Builder
	builder.WriteString("# Generated by ServiceRadar edge onboarding\n")
	builder.WriteString(fmt.Sprintf("# Package: %s (%s)\n", cfg.Label, cfg.PackageID))
	builder.WriteString("# Update values if your environment differs.\n\n")

	for _, key := range keys {
		value := env[key]
		builder.WriteString(fmt.Sprintf("%s=%s\n", key, value))
	}

	return []byte(builder.String()), nil
}

func renderEdgeReadme(result *models.EdgeOnboardingDeliverResult, meta map[string]string) []byte {
	cfg := result.Package
	now := time.Now().UTC().Format(time.RFC3339)
	var builder strings.Builder

	builder.WriteString("ServiceRadar Edge Onboarding Package\n")
	builder.WriteString("====================================\n\n")
	builder.WriteString(fmt.Sprintf("Package ID: %s\n", cfg.PackageID))
	builder.WriteString(fmt.Sprintf("Poller ID : %s\n", cfg.PollerID))
	if cfg.Site != "" {
		builder.WriteString(fmt.Sprintf("Site      : %s\n", cfg.Site))
	}
	builder.WriteString(fmt.Sprintf("Generated : %s\n", now))
	builder.WriteString("\nContents:\n")
	builder.WriteString("  - edge-poller.env\n")
	builder.WriteString("  - metadata.json\n")
	builder.WriteString("  - spire/upstream-join-token\n")
	builder.WriteString("  - spire/upstream-bundle.pem\n")
	builder.WriteString("\nNext steps:\n")
	builder.WriteString("  1. Copy this archive to the edge poller host.\n")
	builder.WriteString("  2. Extract it in the ServiceRadar repository directory:\n")
	builder.WriteString(fmt.Sprintf("       tar -xzvf %s\n", edgePackageDefaultFilename))
	builder.WriteString("  3. Run docker/compose/edge-poller-restart.sh with the generated env file:\n")
	builder.WriteString("       docker/compose/edge-poller-restart.sh --env-file edge-poller.env\n")
	builder.WriteString("  4. Monitor the poller container logs for successful SPIRE bootstrap.\n\n")
	builder.WriteString("The join token expires at ")
	builder.WriteString(cfg.JoinTokenExpiresAt.Format(time.RFC3339))
	builder.WriteString(". Download tokens are single use; reissue if needed.\n")
	if cfg.Notes != "" {
		builder.WriteString("\nOperator notes:\n")
		builder.WriteString(cfg.Notes)
		builder.WriteString("\n")
	}
	if len(meta) > 0 {
		builder.WriteString("\nMetadata summary:\n")
		keys := make([]string, 0, len(meta))
		for key := range meta {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			builder.WriteString(fmt.Sprintf("  %s: %s\n", key, meta[key]))
		}
	}
	builder.WriteString("\nHandle this archive securely; it contains one-time credentials.\n")

	return []byte(builder.String())
}

func renderEdgeMetadataJSON(pkg *models.EdgeOnboardingPackage, meta map[string]string, now time.Time) ([]byte, error) {
	payload := map[string]interface{}{
		"package_id":            pkg.PackageID,
		"label":                 pkg.Label,
		"poller_id":             pkg.PollerID,
		"site":                  pkg.Site,
		"status":                pkg.Status,
		"downstream_spiffe_id":  pkg.DownstreamSPIFFEID,
		"selectors":             pkg.Selectors,
		"join_token_expires_at": pkg.JoinTokenExpiresAt,
		"download_expires_at":   pkg.DownloadTokenExpiresAt,
		"created_by":            pkg.CreatedBy,
		"created_at":            pkg.CreatedAt,
		"updated_at":            pkg.UpdatedAt,
		"delivered_at":          now,
		"notes":                 pkg.Notes,
		"metadata":              meta,
	}
	if pkg.DeliveredAt != nil {
		payload["delivered_at"] = pkg.DeliveredAt.UTC()
	}
	if pkg.ActivatedAt != nil {
		payload["activated_at"] = pkg.ActivatedAt.UTC()
	}
	if pkg.RevokedAt != nil {
		payload["revoked_at"] = pkg.RevokedAt.UTC()
	}
	if pkg.ActivatedFromIP != nil {
		payload["activated_from_ip"] = *pkg.ActivatedFromIP
	}
	if pkg.LastSeenSPIFFEID != nil {
		payload["last_seen_spiffe_id"] = *pkg.LastSeenSPIFFEID
	}
	return json.MarshalIndent(payload, "", "  ")
}

func buildContentDisposition(filename string) string {
	if filename == "" {
		filename = edgePackageDefaultFilename
	}
	return fmt.Sprintf("attachment; filename=%q", filename)
}
