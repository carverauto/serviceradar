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

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/nats/accounts"
)

const (
	defaultNATSOutputDir    = "/etc/nats"
	defaultNATSOperatorName = "serviceradar"
	defaultNATSBootstrapTTL = "24h"
	natsBootstrapEndpoint   = "/api/admin/nats/bootstrap"
	natsStatusEndpoint      = "/api/admin/nats/status"
	natsBootstrapTokenPath  = "/api/admin/nats/bootstrap-token"
	defaultPlatformAccount  = "platform"
	defaultPlatformUser     = "platform-services"
	defaultSystemUser       = "system-resolver"
)

// NatsBootstrapHandler handles flags for the nats-bootstrap subcommand.
type NatsBootstrapHandler struct{}

// Parse processes the command-line arguments for the nats-bootstrap subcommand.
func (NatsBootstrapHandler) Parse(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("nats-bootstrap", flag.ExitOnError)
	coreURL := fs.String("core-url", defaultCoreURL, "ServiceRadar core base URL")
	apiKey := fs.String("api-key", "", "API key for authenticating with core")
	bearer := fs.String("bearer", "", "Bearer token for authenticating with core")
	skipTLS := fs.Bool("tls-skip-verify", false, "Skip TLS certificate verification")
	token := fs.String("token", "", "Platform bootstrap token")
	outputDir := fs.String("output-dir", defaultNATSOutputDir, "Directory to write NATS configuration files")
	operatorName := fs.String("operator-name", defaultNATSOperatorName, "Name for the NATS operator")
	importSeed := fs.String("import-operator-seed", "", "Import existing operator seed instead of generating new")
	verify := fs.Bool("verify", false, "Verify existing NATS bootstrap configuration")
	configPath := fs.String("config", "", "Path to existing nats.conf for verification")
	local := fs.Bool("local", false, "Generate NATS operator and accounts locally without core API")
	noSystemAccount := fs.Bool("no-system-account", false, "Skip system account generation")
	jetstream := fs.Bool("jetstream", true, "Enable JetStream")
	jetstreamDir := fs.String("jetstream-dir", "/var/lib/nats/jetstream", "JetStream storage directory")
	tlsCert := fs.String("tls-cert", "", "Path to TLS certificate for NATS server")
	tlsKey := fs.String("tls-key", "", "Path to TLS private key for NATS server")
	tlsCA := fs.String("tls-ca", "", "Path to TLS CA certificate for client verification")
	noTLS := fs.Bool("no-tls", false, "Disable TLS for NATS server")
	writeSystemCreds := fs.Bool("write-system-creds", true, "Write system account creds when available")
	writePlatform := fs.Bool("write-platform-creds", true, "Generate platform account and creds when possible")
	platformAccount := fs.String("platform-account", defaultPlatformAccount, "Platform account name (empty to skip)")
	platformUser := fs.String("platform-user", defaultPlatformUser, "Platform account user name for creds")
	systemUser := fs.String("system-user", defaultSystemUser, "System account user name for creds")
	output := fs.String("output", "text", "Output format: text or json")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing nats-bootstrap flags: %w", err)
	}

	cfg.CoreAPIURL = *coreURL
	cfg.APIKey = *apiKey
	cfg.BearerToken = *bearer
	cfg.TLSSkipVerify = *skipTLS
	cfg.NATSBootstrapToken = *token
	cfg.NATSOutputDir = *outputDir
	cfg.NATSOperatorName = *operatorName
	cfg.NATSImportSeed = *importSeed
	cfg.NATSVerifyMode = *verify
	cfg.NATSConfigPath = *configPath
	cfg.NATSLocalBootstrap = *local
	cfg.NATSNoSystemAccount = *noSystemAccount
	cfg.NATSJetStream = *jetstream
	cfg.NATSJetStreamDir = *jetstreamDir
	cfg.NATSTLSCert = *tlsCert
	cfg.NATSTLSKey = *tlsKey
	cfg.NATSTLSCA = *tlsCA
	cfg.NATSNoTLS = *noTLS
	cfg.NATSWriteSystemCreds = *writeSystemCreds
	cfg.NATSWritePlatform = *writePlatform
	cfg.NATSPlatformAccount = strings.TrimSpace(*platformAccount)
	cfg.NATSPlatformUser = strings.TrimSpace(*platformUser)
	cfg.NATSSystemUser = strings.TrimSpace(*systemUser)
	cfg.NATSOutputFormat = strings.ToLower(strings.TrimSpace(*output))

	return nil
}

// AdminNatsBootstrapTokenHandler handles generating a new bootstrap token.
type AdminNatsBootstrapTokenHandler struct{}

// Parse processes the command-line arguments for the admin nats generate-bootstrap-token subcommand.
func (AdminNatsBootstrapTokenHandler) Parse(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("admin nats generate-bootstrap-token", flag.ExitOnError)
	coreURL := fs.String("core-url", defaultCoreURL, "ServiceRadar core base URL")
	apiKey := fs.String("api-key", "", "API key for authenticating with core")
	bearer := fs.String("bearer", "", "Bearer token for authenticating with core")
	skipTLS := fs.Bool("tls-skip-verify", false, "Skip TLS certificate verification")
	expires := fs.String("expires", defaultNATSBootstrapTTL, "Token expiration time (e.g., 24h, 4h)")
	output := fs.String("output", "text", "Output format: text or json")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing admin nats generate-bootstrap-token flags: %w", err)
	}

	cfg.CoreAPIURL = *coreURL
	cfg.APIKey = *apiKey
	cfg.BearerToken = *bearer
	cfg.TLSSkipVerify = *skipTLS
	cfg.NATSBootstrapExpires = *expires
	cfg.NATSOutputFormat = strings.ToLower(strings.TrimSpace(*output))

	return nil
}

// natsBootstrapAPIResponse represents the bootstrap response from the Core API.
type natsBootstrapAPIResponse struct {
	OperatorPublicKey      string `json:"operator_public_key"`
	OperatorSeed           string `json:"operator_seed,omitempty"`
	OperatorJWT            string `json:"operator_jwt"`
	SystemAccountPublicKey string `json:"system_account_public_key"`
	SystemAccountSeed      string `json:"system_account_seed,omitempty"`
	SystemAccountJWT       string `json:"system_account_jwt"`
}

// natsBootstrapTokenResponse represents the token generation response.
type natsBootstrapTokenResponse struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

// natsStatusResponse represents the NATS status response.
type natsStatusResponse struct {
	OperatorPublicKey string `json:"operator_public_key"`
	OperatorName      string `json:"operator_name"`
	IsInitialized     bool   `json:"is_initialized"`
}

// RunNatsBootstrap executes the NATS bootstrap process.
func RunNatsBootstrap(cfg *CmdConfig) error {
	if cfg.NATSVerifyMode {
		return runNatsBootstrapVerify(cfg)
	}

	if cfg.NATSLocalBootstrap {
		return runNatsBootstrapLocal(cfg)
	}

	return runNatsBootstrapCreate(cfg)
}

func runNatsBootstrapCreate(cfg *CmdConfig) error {
	if strings.TrimSpace(cfg.NATSBootstrapToken) == "" {
		return errNATSTokenRequired
	}

	coreURL := normaliseCoreURL(cfg.CoreAPIURL)

	// Build bootstrap request
	payload := map[string]interface{}{
		"token":                   strings.TrimSpace(cfg.NATSBootstrapToken),
		"operator_name":           cfg.NATSOperatorName,
		"generate_system_account": !cfg.NATSNoSystemAccount,
	}

	if seed := strings.TrimSpace(cfg.NATSImportSeed); seed != "" {
		payload["existing_operator_seed"] = seed
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode bootstrap request: %w", err)
	}

	// Call bootstrap API
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	endpoint := coreURL + natsBootstrapEndpoint
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create bootstrap request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request NATS bootstrap: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var result natsBootstrapAPIResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode bootstrap response: %w", err)
	}

	// Generate NATS configuration files
	return writeNATSBootstrapFiles(cfg, &result)
}

func runNatsBootstrapLocal(cfg *CmdConfig) error {
	operatorName := cfg.NATSOperatorName
	if operatorName == "" {
		operatorName = defaultNATSOperatorName
	}

	operator, result, err := accounts.BootstrapOperator(
		operatorName,
		strings.TrimSpace(cfg.NATSImportSeed),
		!cfg.NATSNoSystemAccount,
	)
	if err != nil {
		return fmt.Errorf("bootstrap operator locally: %w", err)
	}

	if operator == nil || result == nil {
		return fmt.Errorf("bootstrap operator locally: missing result")
	}

	response := &natsBootstrapAPIResponse{
		OperatorPublicKey:      result.OperatorPublicKey,
		OperatorSeed:           result.OperatorSeed,
		OperatorJWT:            result.OperatorJWT,
		SystemAccountPublicKey: result.SystemAccountPublicKey,
		SystemAccountSeed:      result.SystemAccountSeed,
		SystemAccountJWT:       result.SystemAccountJWT,
	}

	return writeNATSBootstrapFiles(cfg, response)
}

func writeNATSBootstrapFiles(cfg *CmdConfig, result *natsBootstrapAPIResponse) error {
	outputDir := cfg.NATSOutputDir
	if outputDir == "" {
		outputDir = defaultNATSOutputDir
	}

	// Create output directory
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("create output directory %s: %w", outputDir, err)
	}

	// Create JWT resolver directory
	jwtDir := filepath.Join(outputDir, "jwt")
	if err := os.MkdirAll(jwtDir, 0755); err != nil {
		return fmt.Errorf("create JWT directory %s: %w", jwtDir, err)
	}

	// Write operator JWT
	operatorJWTPath := filepath.Join(outputDir, "operator.jwt")
	if err := os.WriteFile(operatorJWTPath, []byte(result.OperatorJWT), 0644); err != nil {
		return fmt.Errorf("write operator JWT: %w", err)
	}

	operatorSeedPath := ""
	if result.OperatorSeed != "" {
		operatorSeedPath = filepath.Join(outputDir, "operator.seed")
		if err := os.WriteFile(operatorSeedPath, []byte(result.OperatorSeed), 0600); err != nil {
			return fmt.Errorf("write operator seed: %w", err)
		}
	}

	// Write system account JWT (into resolver directory)
	systemAccountPublicKeyPath := ""
	if result.SystemAccountJWT != "" {
		systemAcctPath := filepath.Join(jwtDir, result.SystemAccountPublicKey+".jwt")
		if err := os.WriteFile(systemAcctPath, []byte(result.SystemAccountJWT), 0644); err != nil {
			return fmt.Errorf("write system account JWT: %w", err)
		}

		systemJWTPath := filepath.Join(outputDir, "system.jwt")
		if err := os.WriteFile(systemJWTPath, []byte(result.SystemAccountJWT), 0644); err != nil {
			return fmt.Errorf("write system.jwt: %w", err)
		}
	}
	if result.SystemAccountPublicKey != "" {
		systemAccountPublicKeyPath = filepath.Join(outputDir, "system_account.pub")
		if err := os.WriteFile(systemAccountPublicKeyPath, []byte(result.SystemAccountPublicKey), 0644); err != nil {
			return fmt.Errorf("write system account public key: %w", err)
		}
	}

	systemCredsPath := ""
	if cfg.NATSWriteSystemCreds && result.SystemAccountSeed != "" {
		creds, err := generateSystemCreds(result.SystemAccountSeed, cfg.NATSSystemUser)
		if err != nil {
			return fmt.Errorf("generate system creds: %w", err)
		}

		systemCredsPath = filepath.Join(outputDir, "system.creds")
		if err := os.WriteFile(systemCredsPath, []byte(creds), 0600); err != nil {
			return fmt.Errorf("write system.creds: %w", err)
		}
	}

	platformAccount := strings.TrimSpace(cfg.NATSPlatformAccount)
	platformCredsPath := ""
	var platformAccountPublicKey string

	if cfg.NATSWritePlatform && platformAccount != "" {
		operatorName := strings.TrimSpace(cfg.NATSOperatorName)
		if operatorName == "" {
			operatorName = defaultNATSOperatorName
		}

		operatorSeed := strings.TrimSpace(result.OperatorSeed)
		if operatorSeed == "" {
			operatorSeed = strings.TrimSpace(cfg.NATSImportSeed)
		}

		if operatorSeed == "" {
			return fmt.Errorf("platform account requested but operator seed not available")
		}

		platformUser := cfg.NATSPlatformUser
		if platformUser == "" {
			platformUser = defaultPlatformUser
		}

		platformResult, platformCreds, err := generatePlatformAccount(
			operatorSeed,
			operatorName,
			platformAccount,
			result.SystemAccountPublicKey,
			platformUser,
		)
		if err != nil {
			return fmt.Errorf("generate platform account: %w", err)
		}

		platformAccountPublicKey = platformResult.AccountPublicKey
		platformCredsPath = filepath.Join(outputDir, "platform.creds")
		if err := os.WriteFile(platformCredsPath, []byte(platformCreds), 0600); err != nil {
			return fmt.Errorf("write platform.creds: %w", err)
		}

		platformJWTPath := filepath.Join(jwtDir, platformResult.AccountPublicKey+".jwt")
		if err := os.WriteFile(platformJWTPath, []byte(platformResult.AccountJWT), 0644); err != nil {
			return fmt.Errorf("write platform account JWT: %w", err)
		}
	}

	// Generate nats.conf
	natsConfig := edgeonboarding.DefaultNATSServerConfig()
	natsConfig.OperatorJWTPath = operatorJWTPath
	natsConfig.SystemAccountPublicKey = result.SystemAccountPublicKey
	natsConfig.ResolverDir = jwtDir
	natsConfig.JetStreamEnabled = cfg.NATSJetStream
	natsConfig.JetStreamStoreDir = cfg.NATSJetStreamDir
	natsConfig.TLSEnabled = !cfg.NATSNoTLS

	if cfg.NATSTLSCert != "" {
		natsConfig.TLSCertPath = cfg.NATSTLSCert
	}
	if cfg.NATSTLSKey != "" {
		natsConfig.TLSKeyPath = cfg.NATSTLSKey
	}
	if cfg.NATSTLSCA != "" {
		natsConfig.TLSCAPath = cfg.NATSTLSCA
	}

	configContent, err := edgeonboarding.GenerateNATSConfig(natsConfig)
	if err != nil {
		return fmt.Errorf("generate NATS config: %w", err)
	}

	configPath := filepath.Join(outputDir, "nats.conf")
	if err := os.WriteFile(configPath, configContent, 0644); err != nil {
		return fmt.Errorf("write nats.conf: %w", err)
	}

	// Output results
	if cfg.NATSOutputFormat == "json" {
		output := map[string]interface{}{
			"operator_public_key":            result.OperatorPublicKey,
			"system_account_public_key":      result.SystemAccountPublicKey,
			"config_path":                    configPath,
			"operator_jwt_path":              operatorJWTPath,
			"operator_seed_path":             operatorSeedPath,
			"jwt_resolver_dir":               jwtDir,
			"system_account_public_key_path": systemAccountPublicKeyPath,
			"system_creds_path":              systemCredsPath,
			"platform_creds_path":            platformCredsPath,
			"platform_account_public_key":    platformAccountPublicKey,
		}
		if result.OperatorSeed != "" {
			output["operator_seed"] = result.OperatorSeed
		}
		if result.SystemAccountSeed != "" {
			output["system_account_seed"] = result.SystemAccountSeed
		}
		data, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			return fmt.Errorf("encode output: %w", err)
		}
		fmt.Println(string(data))
	} else {
		fmt.Printf("NATS Server Bootstrap Complete\n")
		fmt.Printf("==============================\n")
		fmt.Printf("Operator Public Key    : %s\n", result.OperatorPublicKey)
		fmt.Printf("System Account Key     : %s\n", result.SystemAccountPublicKey)
		fmt.Printf("Configuration File     : %s\n", configPath)
		fmt.Printf("Operator JWT           : %s\n", operatorJWTPath)
		if operatorSeedPath != "" {
			fmt.Printf("Operator Seed File     : %s\n", operatorSeedPath)
		}
		fmt.Printf("JWT Resolver Directory : %s\n", jwtDir)
		if systemAccountPublicKeyPath != "" {
			fmt.Printf("System Account Key File: %s\n", systemAccountPublicKeyPath)
		}
		if systemCredsPath != "" {
			fmt.Printf("System Creds           : %s\n", systemCredsPath)
		}
		if platformCredsPath != "" {
			fmt.Printf("Platform Creds         : %s\n", platformCredsPath)
		}
		if platformAccountPublicKey != "" {
			fmt.Printf("Platform Account Key   : %s\n", platformAccountPublicKey)
		}
		fmt.Println()

		if result.OperatorSeed != "" {
			fmt.Printf("IMPORTANT: Store the operator seed securely!\n")
			fmt.Printf("Operator Seed: %s\n", result.OperatorSeed)
		}
		if result.SystemAccountSeed != "" {
			fmt.Printf("System Account Seed: %s\n", result.SystemAccountSeed)
		}

		fmt.Println()
		fmt.Println("To start NATS server:")
		fmt.Printf("  nats-server -c %s\n", configPath)
	}

	return nil
}

func generateSystemCreds(systemAccountSeed string, userName string) (string, error) {
	if strings.TrimSpace(systemAccountSeed) == "" {
		return "", fmt.Errorf("system account seed is required")
	}

	if userName == "" {
		userName = defaultSystemUser
	}

	permissions := &accounts.UserPermissions{
		PublishAllow:   []string{"$SYS.REQ.ACCOUNT.*.CLAIMS.UPDATE"},
		SubscribeAllow: []string{"_INBOX.>"},
		AllowResponses: true,
		MaxResponses:   10,
	}

	creds, err := accounts.GenerateUserCredentials(
		"SYS",
		systemAccountSeed,
		userName,
		accounts.CredentialTypeService,
		permissions,
		0,
	)
	if err != nil {
		return "", err
	}

	return creds.CredsFileContent, nil
}

func generatePlatformAccount(
	operatorSeed string,
	operatorName string,
	accountName string,
	systemAccountPublicKey string,
	userName string,
) (*accounts.TenantAccountResult, string, error) {
	if strings.TrimSpace(operatorName) == "" {
		operatorName = defaultNATSOperatorName
	}

	cfg := &accounts.OperatorConfig{
		Name:                   operatorName,
		OperatorSeed:           operatorSeed,
		SystemAccountPublicKey: systemAccountPublicKey,
	}

	operator, err := accounts.NewOperator(cfg)
	if err != nil {
		return nil, "", err
	}

	signer := accounts.NewAccountSigner(operator)
	mappings := []accounts.SubjectMapping{
		{From: "events.>", To: "events.>"},
		{From: "snmp.traps", To: "snmp.traps"},
		{From: "logs.>", To: "logs.>"},
		{From: "telemetry.>", To: "telemetry.>"},
		{From: "netflow.>", To: "netflow.>"},
	}

	account, err := signer.CreateTenantAccount(accountName, nil, mappings)
	if err != nil {
		return nil, "", err
	}

	permissions := &accounts.UserPermissions{
		PublishAllow:   []string{">"},
		SubscribeAllow: []string{">"},
		AllowResponses: true,
		MaxResponses:   1000,
	}

	if userName == "" {
		userName = defaultPlatformUser
	}

	creds, err := accounts.GenerateUserCredentials(
		accountName,
		account.AccountSeed,
		userName,
		accounts.CredentialTypeService,
		permissions,
		0,
	)
	if err != nil {
		return nil, "", err
	}

	return account, creds.CredsFileContent, nil
}

func runNatsBootstrapVerify(cfg *CmdConfig) error {
	configPath := cfg.NATSConfigPath
	if configPath == "" {
		configPath = filepath.Join(cfg.NATSOutputDir, "nats.conf")
	}

	// Check if config file exists
	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		return fmt.Errorf("NATS config not found at %s", configPath)
	}

	// Read config file
	content, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("read config file: %w", err)
	}

	// Basic validation - check for required fields
	configStr := string(content)
	checks := []struct {
		name    string
		pattern string
	}{
		{"operator", "operator:"},
		{"system_account", "system_account:"},
		{"resolver", "resolver:"},
	}

	fmt.Printf("Verifying NATS configuration: %s\n", configPath)
	fmt.Println()

	allPassed := true
	for _, check := range checks {
		if strings.Contains(configStr, check.pattern) {
			fmt.Printf("[OK] %s configuration found\n", check.name)
		} else {
			fmt.Printf("[FAIL] %s configuration missing\n", check.name)
			allPassed = false
		}
	}

	// Check operator JWT file
	outputDir := filepath.Dir(configPath)
	operatorJWTPath := filepath.Join(outputDir, "operator.jwt")
	if _, err := os.Stat(operatorJWTPath); err == nil {
		fmt.Printf("[OK] Operator JWT found at %s\n", operatorJWTPath)
	} else {
		fmt.Printf("[FAIL] Operator JWT not found at %s\n", operatorJWTPath)
		allPassed = false
	}

	// Check JWT resolver directory
	jwtDir := filepath.Join(outputDir, "jwt")
	if info, err := os.Stat(jwtDir); err == nil && info.IsDir() {
		fmt.Printf("[OK] JWT resolver directory found at %s\n", jwtDir)
	} else {
		fmt.Printf("[FAIL] JWT resolver directory not found at %s\n", jwtDir)
		allPassed = false
	}

	fmt.Println()
	if allPassed {
		fmt.Println("NATS bootstrap configuration verified successfully.")
		return nil
	}

	return fmt.Errorf("NATS bootstrap verification failed")
}

// RunAdminNatsGenerateBootstrapToken generates a new platform bootstrap token.
func RunAdminNatsGenerateBootstrapToken(cfg *CmdConfig) error {
	coreURL := normaliseCoreURL(cfg.CoreAPIURL)

	// Parse expiration duration
	expiresDuration, err := time.ParseDuration(cfg.NATSBootstrapExpires)
	if err != nil {
		return fmt.Errorf("invalid expiration duration: %w", err)
	}

	payload := map[string]interface{}{
		"expires_in_seconds": int(expiresDuration.Seconds()),
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encode token request: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint := coreURL + natsBootstrapTokenPath
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request bootstrap token: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var result natsBootstrapTokenResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode token response: %w", err)
	}

	if cfg.NATSOutputFormat == "json" {
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return fmt.Errorf("encode output: %w", err)
		}
		fmt.Println(string(data))
	} else {
		fmt.Printf("Bootstrap Token: %s\n", result.Token)
		fmt.Printf("Expires At     : %s\n", result.ExpiresAt.Format(time.RFC3339))
		fmt.Println()
		fmt.Println("Use this token with: serviceradar-cli nats-bootstrap --token <token>")
	}

	return nil
}

// RunAdminNatsStatus retrieves the current NATS operator status.
func RunAdminNatsStatus(cfg *CmdConfig) error {
	coreURL := normaliseCoreURL(cfg.CoreAPIURL)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint := coreURL + natsStatusEndpoint
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create status request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request NATS status: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var result natsStatusResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode status response: %w", err)
	}

	if cfg.NATSOutputFormat == "json" {
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return fmt.Errorf("encode output: %w", err)
		}
		fmt.Println(string(data))
	} else {
		fmt.Printf("NATS Operator Status\n")
		fmt.Printf("====================\n")
		fmt.Printf("Initialized    : %t\n", result.IsInitialized)
		if result.IsInitialized {
			fmt.Printf("Operator Name  : %s\n", result.OperatorName)
			fmt.Printf("Operator Key   : %s\n", result.OperatorPublicKey)
		}
	}

	return nil
}

// AdminNatsHandler handles multi-level `admin nats ...` commands.
type AdminNatsHandler struct{}

// Parse dispatches nested admin nats commands.
func (AdminNatsHandler) Parse(args []string, cfg *CmdConfig) error {
	if len(args) == 0 {
		return errAdminNatsCommandRequired
	}

	action := strings.ToLower(strings.TrimSpace(args[0]))
	cfg.AdminNatsAction = action

	subArgs := args[1:]
	switch action {
	case "generate-bootstrap-token":
		return (AdminNatsBootstrapTokenHandler{}).Parse(subArgs, cfg)
	case "status":
		return parseAdminNatsStatusFlags(subArgs, cfg)
	case "tenants":
		return parseAdminNatsTenantFlags(subArgs, cfg)
	default:
		return fmt.Errorf("%w: %s", errAdminNatsUnknownAction, action)
	}
}

func parseAdminNatsStatusFlags(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("admin nats status", flag.ExitOnError)
	coreURL := fs.String("core-url", defaultCoreURL, "ServiceRadar core base URL")
	apiKey := fs.String("api-key", "", "API key for authenticating with core")
	bearer := fs.String("bearer", "", "Bearer token for authenticating with core")
	skipTLS := fs.Bool("tls-skip-verify", false, "Skip TLS certificate verification")
	output := fs.String("output", "text", "Output format: text or json")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing admin nats status flags: %w", err)
	}

	cfg.CoreAPIURL = *coreURL
	cfg.APIKey = *apiKey
	cfg.BearerToken = *bearer
	cfg.TLSSkipVerify = *skipTLS
	cfg.NATSOutputFormat = strings.ToLower(strings.TrimSpace(*output))

	return nil
}

func parseAdminNatsTenantFlags(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("admin nats tenants", flag.ExitOnError)
	coreURL := fs.String("core-url", defaultCoreURL, "ServiceRadar core base URL")
	apiKey := fs.String("api-key", "", "API key for authenticating with core")
	bearer := fs.String("bearer", "", "Bearer token for authenticating with core")
	skipTLS := fs.Bool("tls-skip-verify", false, "Skip TLS certificate verification")
	output := fs.String("output", "text", "Output format: text or json")
	limit := fs.Int("limit", 50, "Maximum number of tenants to return")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing admin nats tenants flags: %w", err)
	}

	cfg.CoreAPIURL = *coreURL
	cfg.APIKey = *apiKey
	cfg.BearerToken = *bearer
	cfg.TLSSkipVerify = *skipTLS
	cfg.NATSOutputFormat = strings.ToLower(strings.TrimSpace(*output))
	cfg.NATSTenantLimit = *limit

	return nil
}

// RunAdminNatsCommand dispatches admin nats subcommands.
func RunAdminNatsCommand(cfg *CmdConfig) error {
	switch cfg.AdminNatsAction {
	case "generate-bootstrap-token":
		return RunAdminNatsGenerateBootstrapToken(cfg)
	case "status":
		return RunAdminNatsStatus(cfg)
	case "tenants":
		return RunAdminNatsTenants(cfg)
	default:
		return fmt.Errorf("%w: %s", errAdminNatsUnknownAction, cfg.AdminNatsAction)
	}
}

// RunAdminNatsTenants lists all tenant NATS accounts.
func RunAdminNatsTenants(cfg *CmdConfig) error {
	coreURL := normaliseCoreURL(cfg.CoreAPIURL)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint := fmt.Sprintf("%s/api/admin/nats/tenants?limit=%d", coreURL, cfg.NATSTenantLimit)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create tenants request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	applyAuthHeaders(req, cfg)

	resp, err := newHTTPClient(cfg.TLSSkipVerify).Do(req)
	if err != nil {
		return fmt.Errorf("request NATS tenants: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}
		return fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	// Read response body
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	if cfg.NATSOutputFormat == "json" {
		fmt.Println(string(body))
	} else {
		// Parse and display in table format
		var tenants []map[string]interface{}
		if err := json.Unmarshal(body, &tenants); err != nil {
			return fmt.Errorf("decode tenants response: %w", err)
		}

		if len(tenants) == 0 {
			fmt.Println("No tenant NATS accounts found.")
			return nil
		}

		fmt.Printf("%-36s  %-20s  %-15s  %s\n", "TENANT ID", "SLUG", "STATUS", "ACCOUNT KEY")
		fmt.Println(strings.Repeat("-", 100))
		for _, t := range tenants {
			tenantID, _ := t["id"].(string)
			slug, _ := t["slug"].(string)
			status, _ := t["nats_account_status"].(string)
			accountKey, _ := t["nats_account_public_key"].(string)
			fmt.Printf("%-36s  %-20s  %-15s  %s\n", tenantID, slug, status, accountKey)
		}
	}

	return nil
}
