/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package edgeonboarding

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrPackageNotDownloaded is returned when package validation is attempted before download.
	ErrPackageNotDownloaded = errors.New("package not downloaded")
	// ErrDownloadResultNotAvailable is returned when download result is missing.
	ErrDownloadResultNotAvailable = errors.New("download result not available")
	// ErrPackageIDEmpty is returned when package_id is empty.
	ErrPackageIDEmpty = errors.New("package_id is empty")
	// ErrComponentIDEmpty is returned when component_id is empty.
	ErrComponentIDEmpty = errors.New("component_id is empty")
	// ErrComponentTypeNotSet is returned when component_type is not set.
	ErrComponentTypeNotSet = errors.New("component_type is not set")
	// ErrDownstreamSPIFFEIDEmpty is returned when downstream_spiffe_id is empty.
	ErrDownstreamSPIFFEIDEmpty = errors.New("downstream_spiffe_id is empty")
	// ErrJoinTokenEmpty is returned when join token is empty.
	ErrJoinTokenEmpty = errors.New("join token is empty")
	// ErrBundlePEMEmpty is returned when bundle PEM is empty.
	ErrBundlePEMEmpty = errors.New("bundle PEM is empty")
	// ErrDownloadTokenEmpty is returned when the download token segment is missing.
	ErrDownloadTokenEmpty = errors.New("download token is empty")
	// ErrCoreAPIURLRequired is returned when the Core API URL cannot be determined.
	ErrCoreAPIURLRequired = errors.New("core API URL is required")
	// ErrPackageRevoked is returned when package has been revoked.
	ErrPackageRevoked = errors.New("package has been revoked")
	// ErrPackageExpired is returned when package has expired.
	ErrPackageExpired = errors.New("package has expired")
	// ErrPackageDeleted is returned when package has been deleted.
	ErrPackageDeleted = errors.New("package has been deleted")
	// ErrPackageNotDelivered is returned when package is still in issued state.
	ErrPackageNotDelivered = errors.New("package has not been delivered yet")
)

type deliverResponse struct {
	Package   edgePackagePayload `json:"package"`
	JoinToken string             `json:"join_token"`
	BundlePEM string             `json:"bundle_pem"`
}

type edgePackagePayload struct {
	PackageID              string     `json:"package_id"`
	Label                  string     `json:"label"`
	ComponentID            string     `json:"component_id"`
	ComponentType          string     `json:"component_type"`
	ParentType             string     `json:"parent_type"`
	ParentID               string     `json:"parent_id"`
	PollerID               string     `json:"poller_id"`
	Site                   string     `json:"site"`
	Status                 string     `json:"status"`
	DownstreamSPIFFEID     string     `json:"downstream_spiffe_id"`
	Selectors              []string   `json:"selectors"`
	JoinTokenExpiresAt     time.Time  `json:"join_token_expires_at"`
	DownloadTokenExpiresAt time.Time  `json:"download_token_expires_at"`
	CreatedBy              string     `json:"created_by"`
	CreatedAt              time.Time  `json:"created_at"`
	UpdatedAt              time.Time  `json:"updated_at"`
	DeliveredAt            *time.Time `json:"delivered_at"`
	ActivatedAt            *time.Time `json:"activated_at"`
	ActivatedFromIP        *string    `json:"activated_from_ip"`
	LastSeenSPIFFEID       *string    `json:"last_seen_spiffe_id"`
	RevokedAt              *time.Time `json:"revoked_at"`
	DeletedAt              *time.Time `json:"deleted_at"`
	DeletedBy              string     `json:"deleted_by"`
	DeletedReason          string     `json:"deleted_reason"`
	MetadataJSON           string     `json:"metadata_json"`
	CheckerKind            string     `json:"checker_kind"`
	CheckerConfigJSON      string     `json:"checker_config_json"`
	KVRevision             uint64     `json:"kv_revision"`
	Notes                  string     `json:"notes"`
}

// downloadPackage downloads the onboarding package from Core using the token.
// This contacts the Core API to deliver the package, which validates the token
// and marks the package as delivered.
func (b *Bootstrapper) downloadPackage(ctx context.Context) error {
	tokenInfo, err := parseOnboardingToken(b.cfg.Token, b.cfg.PackageID, b.cfg.CoreAPIURL)
	if err != nil {
		return err
	}

	coreURL, err := b.resolveCoreAPIURL(tokenInfo)
	if err != nil {
		return err
	}

	endpoint := fmt.Sprintf("%s/api/admin/edge-packages/%s/download?format=json", coreURL, url.PathEscape(tokenInfo.PackageID))
	payload := map[string]string{"download_token": tokenInfo.DownloadToken}
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode download payload: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create download request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := b.getHTTPClient().Do(req)
	if err != nil {
		return fmt.Errorf("request core deliver endpoint: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		msg := readErrorBody(resp.Body)
		if msg != "" {
			return fmt.Errorf("core deliver endpoint (%s): %s", resp.Status, msg)
		}
		return fmt.Errorf("core deliver endpoint returned %s", resp.Status)
	}

	var deliver deliverResponse
	if err := json.NewDecoder(resp.Body).Decode(&deliver); err != nil {
		return fmt.Errorf("decode deliver response: %w", err)
	}

	pkg, err := deliver.Package.toModel()
	if err != nil {
		return fmt.Errorf("invalid package payload: %w", err)
	}

	b.pkg = pkg
	b.downloadResult = &models.EdgeOnboardingDeliverResult{
		Package:   pkg,
		JoinToken: deliver.JoinToken,
		BundlePEM: []byte(deliver.BundlePEM),
	}
	b.tokenInfo = tokenInfo

	b.logger.Info().
		Str("package_id", pkg.PackageID).
		Str("component_id", pkg.ComponentID).
		Str("core_api_url", coreURL).
		Msg("Downloaded edge onboarding package")

	return nil
}

// validatePackage validates the downloaded package contents.
func (b *Bootstrapper) validatePackage(ctx context.Context) error {
	_ = ctx

	if b.pkg == nil {
		return ErrPackageNotDownloaded
	}

	if b.downloadResult == nil {
		return ErrDownloadResultNotAvailable
	}

	// Validate package fields
	if b.pkg.PackageID == "" {
		return ErrPackageIDEmpty
	}

	if b.pkg.ComponentID == "" {
		return ErrComponentIDEmpty
	}

	if b.pkg.ComponentType == models.EdgeOnboardingComponentTypeNone {
		return ErrComponentTypeNotSet
	}

	if b.pkg.DownstreamSPIFFEID == "" {
		return ErrDownstreamSPIFFEIDEmpty
	}

	// Validate SPIRE credentials
	if b.downloadResult.JoinToken == "" {
		return ErrJoinTokenEmpty
	}

	if len(b.downloadResult.BundlePEM) == 0 {
		return ErrBundlePEMEmpty
	}

	// Validate package status
	switch b.pkg.Status {
	case models.EdgeOnboardingStatusDelivered, models.EdgeOnboardingStatusActivated:
		// Valid statuses for onboarding
	case models.EdgeOnboardingStatusIssued:
		return fmt.Errorf("%w: id %s", ErrPackageNotDelivered, b.pkg.PackageID)
	case models.EdgeOnboardingStatusRevoked:
		return ErrPackageRevoked
	case models.EdgeOnboardingStatusExpired:
		return ErrPackageExpired
	case models.EdgeOnboardingStatusDeleted:
		return ErrPackageDeleted
	default:
		b.logger.Warn().
			Str("status", string(b.pkg.Status)).
			Msg("Package has unexpected status, proceeding anyway")
	}

	b.logger.Debug().
		Str("package_id", b.pkg.PackageID).
		Str("component_id", b.pkg.ComponentID).
		Str("spiffe_id", b.pkg.DownstreamSPIFFEID).
		Msg("Package validation successful")

	return nil
}

// markActivated notifies Core that the package has been activated.
// This is done by the service when it successfully starts up with the credentials.
func (b *Bootstrapper) markActivated(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	// TODO: Implement activation notification
	// This could be done via:
	// 1. Direct gRPC call to Core (requires Core to expose this endpoint)
	// 2. Automatic detection when service first connects with SPIFFE ID
	// 3. KV update that Core monitors

	// For now, we'll log and continue - Core will detect activation when
	// the service first reports status with the SPIFFE ID
	b.logger.Debug().
		Str("package_id", b.pkg.PackageID).
		Msg("Package activation will be detected by Core on first status report")

	return nil
}

func (b *Bootstrapper) resolveCoreAPIURL(tokenInfo *tokenPayload) (string, error) {
	candidates := []string{
		b.cfg.CoreAPIURL,
		tokenInfo.CoreURL,
		os.Getenv("CORE_API_URL"),
	}

	var lastErr error
	for _, candidate := range candidates {
		if strings.TrimSpace(candidate) == "" {
			continue
		}
		normalized, err := normalizeBaseURL(candidate)
		if err != nil {
			lastErr = err
			continue
		}
		b.cfg.CoreAPIURL = normalized
		return normalized, nil
	}

	if lastErr != nil {
		return "", lastErr
	}
	return "", ErrCoreAPIURLRequired
}

func (b *Bootstrapper) getHTTPClient() *http.Client {
	if b.httpClient != nil {
		return b.httpClient
	}
	b.httpClient = &http.Client{
		Timeout: 20 * time.Second,
	}
	return b.httpClient
}

func normalizeBaseURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", ErrCoreAPIURLRequired
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("parse core api url: %w", err)
	}
	if u.Scheme == "" {
		u.Scheme = "https"
	}
	if u.Host == "" {
		return "", fmt.Errorf("core api url missing host")
	}
	u.RawQuery = ""
	u.Fragment = ""
	u.Path = strings.TrimRight(u.Path, "/")
	return strings.TrimRight(u.String(), "/"), nil
}

func readErrorBody(body io.Reader) string {
	if body == nil {
		return ""
	}
	data, err := io.ReadAll(io.LimitReader(body, 4096))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func (p edgePackagePayload) toModel() (*models.EdgeOnboardingPackage, error) {
	if strings.TrimSpace(p.PackageID) == "" {
		return nil, ErrPackageIDEmpty
	}
	componentType := models.EdgeOnboardingComponentType(strings.TrimSpace(p.ComponentType))
	parentType := models.EdgeOnboardingComponentType(strings.TrimSpace(p.ParentType))
	status := models.EdgeOnboardingStatus(strings.TrimSpace(p.Status))

	pkg := &models.EdgeOnboardingPackage{
		PackageID:              p.PackageID,
		Label:                  p.Label,
		ComponentID:            p.ComponentID,
		ComponentType:          componentType,
		ParentType:             parentType,
		ParentID:               p.ParentID,
		PollerID:               p.PollerID,
		Site:                   p.Site,
		Status:                 status,
		DownstreamSPIFFEID:     p.DownstreamSPIFFEID,
		Selectors:              append([]string(nil), p.Selectors...),
		JoinTokenExpiresAt:     p.JoinTokenExpiresAt,
		DownloadTokenExpiresAt: p.DownloadTokenExpiresAt,
		CreatedBy:              p.CreatedBy,
		CreatedAt:              p.CreatedAt,
		UpdatedAt:              p.UpdatedAt,
		MetadataJSON:           p.MetadataJSON,
		CheckerKind:            p.CheckerKind,
		CheckerConfigJSON:      p.CheckerConfigJSON,
		KVRevision:             p.KVRevision,
		Notes:                  p.Notes,
	}

	if p.DeliveredAt != nil {
		pkg.DeliveredAt = p.DeliveredAt
	}
	if p.ActivatedAt != nil {
		pkg.ActivatedAt = p.ActivatedAt
	}
	if p.ActivatedFromIP != nil {
		pkg.ActivatedFromIP = p.ActivatedFromIP
	}
	if p.LastSeenSPIFFEID != nil {
		pkg.LastSeenSPIFFEID = p.LastSeenSPIFFEID
	}
	if p.RevokedAt != nil {
		pkg.RevokedAt = p.RevokedAt
	}
	if p.DeletedAt != nil {
		pkg.DeletedAt = p.DeletedAt
	}
	if p.DeletedBy != "" {
		pkg.DeletedBy = p.DeletedBy
	}
	if p.DeletedReason != "" {
		pkg.DeletedReason = p.DeletedReason
	}

	return pkg, nil
}

// min returns the minimum of two integers.
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
