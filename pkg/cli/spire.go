package cli

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const defaultCoreURL = "http://localhost:8090"

type joinTokenRequest struct {
	ClientSPIFFEID     string             `json:"client_spiffe_id,omitempty"`
	TTLSeconds         int                `json:"ttl_seconds,omitempty"`
	RegisterDownstream bool               `json:"register_downstream,omitempty"`
	Downstream         *downstreamRequest `json:"downstream,omitempty"`
}

type downstreamRequest struct {
	SpiffeID           string   `json:"spiffe_id"`
	Selectors          []string `json:"selectors"`
	X509SVIDTTLSeconds int      `json:"x509_svid_ttl_seconds,omitempty"`
	JWTSVIDTTLSeconds  int      `json:"jwt_svid_ttl_seconds,omitempty"`
	Admin              bool     `json:"admin,omitempty"`
	StoreSVID          bool     `json:"store_svid,omitempty"`
	DNSNames           []string `json:"dns_names,omitempty"`
	FederatesWith      []string `json:"federates_with,omitempty"`
}

type joinTokenResponse struct {
	Token             string    `json:"token"`
	ExpiresAt         time.Time `json:"expires_at"`
	ParentSPIFFEID    string    `json:"parent_spiffe_id"`
	DownstreamEntryID string    `json:"downstream_entry_id,omitempty"`
}

// RunSpireJoinToken executes the spire-join-token subcommand.
func RunSpireJoinToken(cfg *CmdConfig) error {
	if cfg.CoreAPIURL == "" {
		return errCoreURLRequired
	}

	baseURL := strings.TrimSuffix(cfg.CoreAPIURL, "/")
	if !strings.HasPrefix(baseURL, "http://") && !strings.HasPrefix(baseURL, "https://") {
		baseURL = "https://" + baseURL
	}
	endpoint, err := url.JoinPath(baseURL, "/api/admin/spire/join-tokens")
	if err != nil {
		return fmt.Errorf("build join token endpoint: %w", err)
	}

	req := joinTokenRequest{
		ClientSPIFFEID: cfg.AgentSPIFFEID,
	}

	if cfg.JoinTokenTTLSeconds > 0 {
		req.TTLSeconds = cfg.JoinTokenTTLSeconds
	}

	if !cfg.NoDownstream {
		if cfg.DownstreamSPIFFEID == "" {
			return errDownstreamSPIFFEID
		}
		if len(cfg.DownstreamSelectors) == 0 {
			return errDownstreamSelectors
		}

		req.RegisterDownstream = true
		req.Downstream = &downstreamRequest{
			SpiffeID:           cfg.DownstreamSPIFFEID,
			Selectors:          cfg.DownstreamSelectors,
			X509SVIDTTLSeconds: cfg.DownstreamX509TTLSeconds,
			JWTSVIDTTLSeconds:  cfg.DownstreamJWTTTLSeconds,
			Admin:              cfg.DownstreamAdmin,
			StoreSVID:          cfg.DownstreamStoreSVID,
			DNSNames:           cfg.DownstreamDNSNames,
			FederatesWith:      cfg.DownstreamFederates,
		}
	}

	body, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("encode join token request: %w", err)
	}

	httpReq, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if cfg.BearerToken != "" {
		httpReq.Header.Set("Authorization", "Bearer "+cfg.BearerToken)
	} else if cfg.APIKey != "" {
		httpReq.Header.Set("X-API-Key", cfg.APIKey)
	}

	client := &http.Client{Timeout: 15 * time.Second}
	if strings.HasPrefix(baseURL, "https://") && cfg.TLSSkipVerify {
		transport := http.DefaultTransport.(*http.Transport).Clone()
		if transport.TLSClientConfig == nil {
			transport.TLSClientConfig = &tls.Config{}
		}
		transport.TLSClientConfig.InsecureSkipVerify = true
		client.Transport = transport
	}

	resp, err := client.Do(httpReq)
	if err != nil {
		return fmt.Errorf("call core API: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		errorBody, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		errorText := strings.TrimSpace(string(errorBody))
		if errorText == "" {
			errorText = resp.Status
		}
		return fmt.Errorf("core API error: %s", errorText)
	}

	var result joinTokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode join token response: %w", err)
	}

	if cfg.JoinTokenOutput != "" {
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return fmt.Errorf("encode response: %w", err)
		}
		if err := os.WriteFile(cfg.JoinTokenOutput, data, 0o600); err != nil {
			return fmt.Errorf("write response to %s: %w", cfg.JoinTokenOutput, err)
		}
		fmt.Printf("Join token response saved to %s\n", cfg.JoinTokenOutput)
	}

	fmt.Printf("Join token: %s\n", result.Token)
	fmt.Printf("Parent SPIFFE ID: %s\n", result.ParentSPIFFEID)
	fmt.Printf("Expires At: %s\n", result.ExpiresAt.Format(time.RFC3339))
	if result.DownstreamEntryID != "" {
		fmt.Printf("Downstream Entry ID: %s\n", result.DownstreamEntryID)
	}

	return nil
}
