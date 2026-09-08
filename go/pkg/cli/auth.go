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
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"
)

// sortedKeys returns the store's instance URLs in stable order.
func sortedKeys(instances map[string]authCredentialEntry) []string {
	keys := make([]string, 0, len(instances))
	for key := range instances {
		keys = append(keys, key)
	}

	slices.Sort(keys)

	return keys
}

// Device-code auth (RFC 8628) client for `srctl auth login|status|logout`.
//
// The server side already exists (POST /api/v1/cli/auth/device and
// POST /api/v1/cli/auth/token); this file is the Go client. Issued JWTs are
// persisted in the same store as the JS CLI (`~/.config/serviceradar/credentials.json`,
// `%APPDATA%\serviceradar\credentials.json` on Windows) so both CLIs share logins.

const (
	authCommandLogin     = "login"
	authCommandStatus    = "status"
	authCommandLogout    = "logout"
	authCommandBcryptGen = "bcrypt-gen"

	// authClientID is the registered client identifier the server allowlists.
	// It stays "serviceradar-cli" after the binary rename to srctl: deployed
	// servers only accept that value, and the id names the CLI product family.
	authClientID = "serviceradar-cli"

	authDeviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"
	authDefaultScope    = "dashboard.publish"

	authCredentialsDirName  = "serviceradar"
	authCredentialsFileName = "credentials.json"
	authCredentialsVersion  = 1

	authFilePerms = 0600
	authDirPerms  = 0700

	authOSWindows = "windows"
)

// authOutput funnels terminal output through one writer, keeping the first
// write error for the caller. Methods intentionally return nothing so every
// write site stays a single line without unchecked errors.
type authOutput struct {
	writer io.Writer
	err    error
}

func (o *authOutput) println(args ...any) {
	if o.err != nil {
		return
	}

	_, o.err = fmt.Fprintln(o.writer, args...)
}

func (o *authOutput) printf(format string, args ...any) {
	if o.err != nil {
		return
	}

	_, o.err = fmt.Fprintf(o.writer, format, args...)
}

// authCredentialEntry is one stored login. The token itself is never printed.
type authCredentialEntry struct {
	Token      string `json:"token"`
	User       string `json:"user,omitempty"`
	ObtainedAt string `json:"obtained_at,omitempty"`
	ExpiresAt  string `json:"expires_at,omitempty"`
}

// authCredentialStore is the on-disk shape, shared with the JS CLI.
type authCredentialStore struct {
	Version   int                            `json:"version"`
	Instances map[string]authCredentialEntry `json:"instances"`
}

// AuthHandler handles the multi-level `auth ...` commands.
type AuthHandler struct{}

// Parse dispatches nested auth commands (login, status, logout).
func (AuthHandler) Parse(args []string, cfg *CmdConfig) error {
	if len(args) == 0 {
		return errAuthActionRequired
	}

	action := strings.ToLower(strings.TrimSpace(args[0]))
	cfg.AuthCommand = action

	switch action {
	case authCommandLogin:
		return parseAuthLoginFlags(args[1:], cfg)
	case authCommandStatus, authCommandLogout:
		return parseAuthFilterFlags(action, args[1:], cfg)
	case authCommandBcryptGen:
		return parseAuthBcryptGenFlags(args[1:], cfg)
	default:
		return fmt.Errorf("%w: %s", errAuthUnknownAction, action)
	}
}

func parseAuthLoginFlags(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("auth login", flag.ExitOnError)
	instance := fs.String("instance", defaultCoreURL, "ServiceRadar instance base URL")
	scope := fs.String("scope", authDefaultScope, "OAuth scope to request")
	noBrowser := fs.Bool("no-browser", false, "Print the verification URL without opening a browser")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing auth login flags: %w", err)
	}

	cfg.AuthInstance = *instance
	cfg.AuthScope = *scope
	cfg.AuthNoBrowser = *noBrowser

	return nil
}

func parseAuthFilterFlags(action string, args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("auth "+action, flag.ExitOnError)
	instance := fs.String("instance", "", "Only show or remove the credential for this instance")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing auth %s flags: %w", action, err)
	}

	cfg.AuthInstance = *instance

	return nil
}

// parseAuthBcryptGenFlags parses `auth bcrypt-gen --password <pw>`, the
// invocation the Helm secret-generator hook uses to mint the admin hash.
func parseAuthBcryptGenFlags(args []string, cfg *CmdConfig) error {
	fs := flag.NewFlagSet("auth bcrypt-gen", flag.ExitOnError)
	password := fs.String("password", "", "Password to hash")

	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("parsing auth bcrypt-gen flags: %w", err)
	}

	cfg.AuthPassword = *password

	return nil
}

// RunAuthCommand dispatches `srctl auth ...` invocations.
func RunAuthCommand(cfg *CmdConfig) error {
	switch cfg.AuthCommand {
	case authCommandLogin:
		return RunAuthLogin(cfg)
	case authCommandStatus:
		return RunAuthStatus(cfg)
	case authCommandLogout:
		return RunAuthLogout(cfg)
	case authCommandBcryptGen:
		return RunAuthBcryptGen(cfg)
	default:
		return fmt.Errorf("%w: %s", errAuthUnknownAction, cfg.AuthCommand)
	}
}

// RunAuthLogin performs the RFC 8628 device-code flow and stores the JWT.
func RunAuthLogin(cfg *CmdConfig) error {
	instance := normalizeAuthInstance(cfg.AuthInstance)
	if instance == "" {
		return errAuthInstanceRequired
	}
	if !isHTTPURL(instance) {
		return fmt.Errorf("%w: %s", errAuthInstanceURL, instance)
	}

	scope := strings.TrimSpace(cfg.AuthScope)
	if scope == "" {
		scope = authDefaultScope
	}

	entry, err := runDeviceCodeFlow(newHTTPClient(), instance, scope, !cfg.AuthNoBrowser, os.Stdout)
	if err != nil {
		return err
	}

	if err := upsertStoredCredential(instance, entry); err != nil {
		return err
	}

	fmt.Printf("Authenticated%s\n", formatAuthUserSuffix(entry.User))
	fmt.Printf("Token stored at %s\n", credentialsPath())

	return nil
}

// RunAuthStatus prints stored logins without ever revealing tokens.
func RunAuthStatus(cfg *CmdConfig) error {
	return writeAuthStatus(os.Stdout, authFilter(cfg))
}

// RunAuthLogout removes a stored login.
func RunAuthLogout(cfg *CmdConfig) error {
	return writeAuthLogout(os.Stdout, authFilter(cfg))
}

// RunAuthBcryptGen prints a bcrypt hash of --password. It backs the
// `auth bcrypt-gen --password <pw>` call the Helm secret-generator hook makes.
func RunAuthBcryptGen(cfg *CmdConfig) error {
	if cfg.AuthPassword == "" {
		return errAuthPasswordRequired
	}

	return RunBcryptNonInteractive([]string{cfg.AuthPassword})
}

// authFilter normalises the optional --instance filter. Empty stays empty
// (list/remove across all stored logins); only an explicit value is
// canonicalised into a store key.
func authFilter(cfg *CmdConfig) string {
	if strings.TrimSpace(cfg.AuthInstance) == "" {
		return ""
	}

	return normalizeAuthInstance(cfg.AuthInstance)
}

func writeAuthStatus(writer io.Writer, filter string) error {
	out := &authOutput{writer: writer}

	store, err := readCredentialStore()
	if err != nil {
		return err
	}

	if len(store.Instances) == 0 {
		out.println("No stored credentials.")
		out.println("Run `srctl auth login --instance <url>` to authenticate.")

		return out.err
	}

	matched := false

	for _, url := range sortedKeys(store.Instances) {
		if filter != "" && filter != url {
			continue
		}

		matched = true
		entry := store.Instances[url]
		out.printf("Instance: %s\n", url)
		out.printf("  user:        %s\n", defaultIfEmpty(entry.User, "(unknown)"))
		out.printf("  obtained_at: %s\n", defaultIfEmpty(entry.ObtainedAt, "(unknown)"))
		out.printf("  expires_at:  %s\n", defaultIfEmpty(entry.ExpiresAt, "(no expiry recorded)"))
	}

	if !matched {
		out.printf("No credential stored for %s\n", filter)
	}

	return out.err
}

func writeAuthLogout(writer io.Writer, filter string) error {
	out := &authOutput{writer: writer}

	if filter != "" {
		removed, err := deleteStoredCredential(filter)
		if err != nil {
			return err
		}

		if removed {
			out.printf("Removed credential for %s\n", filter)
		} else {
			out.printf("No credential stored for %s\n", filter)
		}

		return out.err
	}

	store, err := readCredentialStore()
	if err != nil {
		return err
	}

	urls := sortedKeys(store.Instances)
	switch len(urls) {
	case 0:
		out.println("No stored credentials to remove.")
	case 1:
		if _, err := deleteStoredCredential(urls[0]); err != nil {
			return err
		}

		out.printf("Removed credential for %s\n", urls[0])
	default:
		return fmt.Errorf("%w. Stored:\n  %s", errAuthAmbiguousLogout, strings.Join(urls, "\n  "))
	}

	return out.err
}

// normalizeAuthInstance canonicalises the store key exactly as the JS CLI's
// normalizeInstanceUrl does: trim, then strip trailing slashes. No scheme is
// invented, so a scheme-less value stays scheme-less and RunAuthLogin rejects
// it rather than storing a key the JS CLI could never look up.
func normalizeAuthInstance(raw string) string {
	return strings.TrimRight(strings.TrimSpace(raw), "/")
}

// isHTTPURL reports whether raw is an absolute http(s) URL.
func isHTTPURL(raw string) bool {
	return strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://")
}

func formatAuthUserSuffix(user string) string {
	if strings.TrimSpace(user) == "" {
		return ""
	}

	return " as " + user
}

func defaultIfEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}

	return value
}

// authDeviceResponse is the RFC 8628 section 3.2 success payload.
type authDeviceResponse struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

// authTokenSuccess is the issued-token envelope (same shape as the OAuth grants).
type authTokenSuccess struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int    `json:"expires_in"`
	ExpiresAt   string `json:"expires_at"`
	Scope       string `json:"scope"`
	User        any    `json:"user"`
	Email       string `json:"email"`
}

// authTokenError is the RFC 8628 section 3.5 error envelope (HTTP 400).
type authTokenError struct {
	Error            string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

// runDeviceCodeFlow executes the device-code exchange against instance.
// Poll errors that are part of the protocol (pending, slow_down) are handled;
// terminal states surface as errors with a login hint.
func runDeviceCodeFlow(client *http.Client, instance, scope string, openBrowser bool, writer io.Writer) (authCredentialEntry, error) {
	return runDeviceCodeFlowWithClock(client, instance, scope, openBrowser, writer, time.Now, time.Sleep)
}

func runDeviceCodeFlowWithClock(client *http.Client, instance, scope string, openBrowser bool, writer io.Writer, now func() time.Time, sleep func(time.Duration)) (authCredentialEntry, error) {
	device, err := requestDeviceCode(client, instance, scope)
	if err != nil {
		return authCredentialEntry{}, err
	}

	verificationURI := device.VerificationURIComplete
	if verificationURI == "" {
		verificationURI = device.VerificationURI
	}

	if device.DeviceCode == "" || verificationURI == "" {
		return authCredentialEntry{}, fmt.Errorf("%w: device-code response missing fields", errAuthFlowFailed)
	}

	if !isHTTPURL(verificationURI) {
		return authCredentialEntry{}, fmt.Errorf("%w: verification_uri is not an http(s) URL", errAuthFlowFailed)
	}

	interval := time.Duration(max(device.Interval, 1)) * time.Second
	expiresIn := device.ExpiresIn
	if expiresIn <= 0 {
		expiresIn = 900
	}

	deadline := now().Add(time.Duration(expiresIn) * time.Second)

	out := &authOutput{writer: writer}
	out.println("")
	out.println("To finish authenticating, open this URL in a browser:")
	out.printf("  %s\n", verificationURI)
	if device.UserCode != "" {
		out.printf("Enter this code if prompted: %s\n", device.UserCode)
	}
	out.println("")

	if out.err != nil {
		return authCredentialEntry{}, out.err
	}

	if openBrowser {
		openBrowserURL(verificationURI)
	}

	for now().Before(deadline) {
		sleep(interval)

		entry, pollErr := pollDeviceToken(client, instance, device.DeviceCode)
		if pollErr == nil {
			return entry, nil
		}

		var stateErr *authFlowStateError
		if !errors.As(pollErr, &stateErr) {
			return authCredentialEntry{}, pollErr
		}

		switch stateErr.Code {
		case "authorization_pending":
			continue
		case "slow_down":
			interval += 5 * time.Second

			continue
		case "access_denied":
			return authCredentialEntry{}, fmt.Errorf("%w: device login was denied", errAuthDenied)
		case "expired_token":
			return authCredentialEntry{}, fmt.Errorf("%w: device code expired before login completed", errAuthExpired)
		default:
			return authCredentialEntry{}, pollErr
		}
	}

	return authCredentialEntry{}, fmt.Errorf("%w: device login timed out; run `srctl auth login` again", errAuthExpired)
}

// authFlowStateError is a recoverable RFC 8628 polling state, not a failure.
type authFlowStateError struct {
	Code        string
	Description string
}

func (e *authFlowStateError) Error() string {
	if e.Description != "" {
		return e.Code + ": " + e.Description
	}

	return e.Code
}

func requestDeviceCode(client *http.Client, instance, scope string) (*authDeviceResponse, error) {
	body, err := json.Marshal(map[string]string{
		"client_id": authClientID,
		"scope":     scope,
	})
	if err != nil {
		return nil, fmt.Errorf("encode device-code request: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint := instance + "/api/v1/cli/auth/device"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create device-code request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("device-code request failed: %w", err)
	}

	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("%w: this instance does not expose device-code login (HTTP 404)", errAuthFlowFailed)
	}

	if resp.StatusCode == http.StatusServiceUnavailable {
		return nil, fmt.Errorf("%w: %s", errAuthDisabled, readErrorBody(resp.Body))
	}

	if resp.StatusCode != http.StatusOK {
		message := readErrorBody(resp.Body)
		if message == "" {
			message = resp.Status
		}

		return nil, fmt.Errorf("%w: %s", errCoreAPIError, message)
	}

	var device authDeviceResponse
	if err := json.NewDecoder(resp.Body).Decode(&device); err != nil {
		return nil, fmt.Errorf("decode device-code response: %w", err)
	}

	return &device, nil
}

// pollDeviceToken performs one token poll. Success returns the entry, a
// protocol wait returns *authFlowStateError, and anything else is fatal.
func pollDeviceToken(client *http.Client, instance, deviceCode string) (authCredentialEntry, error) {
	body, err := json.Marshal(map[string]string{
		"grant_type":  authDeviceGrantType,
		"device_code": deviceCode,
	})
	if err != nil {
		return authCredentialEntry{}, fmt.Errorf("encode token request: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	endpoint := instance + "/api/v1/cli/auth/token"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return authCredentialEntry{}, fmt.Errorf("create token request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return authCredentialEntry{}, fmt.Errorf("device-code poll failed: %w", err)
	}

	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusOK {
		var success authTokenSuccess
		if err := json.NewDecoder(resp.Body).Decode(&success); err != nil {
			return authCredentialEntry{}, fmt.Errorf("decode token response: %w", err)
		}

		if strings.TrimSpace(success.AccessToken) == "" {
			return authCredentialEntry{}, fmt.Errorf("%w: token response missing access_token", errAuthFlowFailed)
		}

		return authCredentialEntry{
			Token:      success.AccessToken,
			User:       extractAuthUserLabel(success),
			ObtainedAt: time.Now().UTC().Format(time.RFC3339),
			ExpiresAt:  authExpiry(success),
		}, nil
	}

	var tokenErr authTokenError
	if err := json.NewDecoder(resp.Body).Decode(&tokenErr); err != nil || tokenErr.Error == "" {
		return authCredentialEntry{}, fmt.Errorf("%w: token poll failed: %s", errCoreAPIError, resp.Status)
	}

	return authCredentialEntry{}, &authFlowStateError{Code: tokenErr.Error, Description: tokenErr.ErrorDescription}
}

func authExpiry(success authTokenSuccess) string {
	if strings.TrimSpace(success.ExpiresAt) != "" {
		return success.ExpiresAt
	}

	if success.ExpiresIn > 0 {
		return time.Now().UTC().Add(time.Duration(success.ExpiresIn) * time.Second).Format(time.RFC3339)
	}

	return ""
}

// extractAuthUserLabel mirrors the JS CLI: nested {id, email} object, bare
// string, top-level email, or empty.
func extractAuthUserLabel(success authTokenSuccess) string {
	switch user := success.User.(type) {
	case string:
		return user
	case map[string]any:
		if email, ok := user["email"].(string); ok && email != "" {
			return email
		}

		if id, ok := user["id"].(string); ok {
			return id
		}
	}

	return success.Email
}

// openBrowserURL opens the verification URL best-effort; a failure only means
// the user copies the printed URL by hand. The opener is detached from the
// login flow: a timeout kills a hung opener, and a reaper collects it.
func openBrowserURL(rawURL string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)

	var cmd *exec.Cmd

	switch runtime.GOOS {
	case "darwin":
		cmd = exec.CommandContext(ctx, "open", rawURL)
	case authOSWindows:
		cmd = exec.CommandContext(ctx, "rundll32", "url.dll,FileProtocolHandler", rawURL)
	default:
		cmd = exec.CommandContext(ctx, "xdg-open", rawURL)
	}

	if err := cmd.Start(); err != nil {
		cancel()

		return
	}

	go func() {
		defer cancel()
		_ = cmd.Wait()
	}()
}

// credentialsDir returns the OS-appropriate credential directory.
func credentialsDir() string {
	if runtime.GOOS == authOSWindows {
		if appData := strings.TrimSpace(os.Getenv("APPDATA")); appData != "" {
			return filepath.Join(appData, authCredentialsDirName)
		}

		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, authCredentialsDirName)
		}

		return authCredentialsDirName
	}

	if xdg := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME")); xdg != "" {
		return filepath.Join(xdg, authCredentialsDirName)
	}

	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".config", authCredentialsDirName)
	}

	return filepath.Join(".", ".config", authCredentialsDirName)
}

// credentialsPath returns the OS-appropriate credential file path.
func credentialsPath() string {
	return filepath.Join(credentialsDir(), authCredentialsFileName)
}

func readCredentialStore() (authCredentialStore, error) {
	store := authCredentialStore{Version: authCredentialsVersion, Instances: map[string]authCredentialEntry{}}

	data, err := os.ReadFile(credentialsPath())
	if err != nil {
		if os.IsNotExist(err) {
			return store, nil
		}

		return store, fmt.Errorf("read credential store: %w", err)
	}

	var raw authCredentialStore
	if err := json.Unmarshal(data, &raw); err != nil {
		return store, nil
	}

	if raw.Instances != nil {
		store.Instances = raw.Instances
	}

	return store, nil
}

func writeCredentialStore(store authCredentialStore) error {
	dir := credentialsDir()
	if err := ensureSafeCredentialDir(dir); err != nil {
		return err
	}

	data, err := json.MarshalIndent(authCredentialStore{Version: authCredentialsVersion, Instances: store.Instances}, "", "  ")
	if err != nil {
		return fmt.Errorf("encode credential store: %w", err)
	}

	data = append(data, '\n')

	return writeCredentialFileAtomically(credentialsPath(), data)
}

// writeCredentialFileAtomically writes via a sibling temp file and renames it
// over the target, so an interrupted write leaves the previous store intact
// instead of truncated JSON that readCredentialStore would treat as empty.
func writeCredentialFileAtomically(path string, data []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(path), authCredentialsFileName+".*.tmp")
	if err != nil {
		return fmt.Errorf("write credential store: %w", err)
	}

	tempPath := temp.Name()

	defer func() {
		_ = temp.Close()
		_ = os.Remove(tempPath)
	}()

	if err := temp.Chmod(authFilePerms); err != nil {
		return fmt.Errorf("secure credential store: %w", err)
	}

	if _, err := temp.Write(data); err != nil {
		return fmt.Errorf("write credential store: %w", err)
	}

	if err := temp.Close(); err != nil {
		return fmt.Errorf("write credential store: %w", err)
	}

	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("write credential store: %w", err)
	}

	return nil
}

// ensureSafeCredentialDir creates the store directory owner-only and refuses a
// group- or world-writable one, mirroring the JS CLI.
func ensureSafeCredentialDir(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("stat credential directory: %w", err)
		}

		if err := os.MkdirAll(dir, authDirPerms); err != nil {
			return fmt.Errorf("create credential directory: %w", err)
		}

		return nil
	}

	if !info.IsDir() {
		return fmt.Errorf("%w: %s", errCredentialNotDir, dir)
	}

	if runtime.GOOS != authOSWindows && info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("%w: %s", errCredentialDirUnsafe, dir)
	}

	return nil
}

func upsertStoredCredential(instance string, entry authCredentialEntry) error {
	url := normalizeAuthInstance(instance)
	if url == "" {
		return errAuthInstanceRequired
	}

	store, err := readCredentialStore()
	if err != nil {
		return err
	}

	store.Instances[url] = entry

	return writeCredentialStore(store)
}

func deleteStoredCredential(instance string) (bool, error) {
	url := normalizeAuthInstance(instance)
	if url == "" {
		return false, errAuthInstanceRequired
	}

	store, err := readCredentialStore()
	if err != nil {
		return false, err
	}

	if _, ok := store.Instances[url]; !ok {
		return false, nil
	}

	delete(store.Instances, url)

	return true, writeCredentialStore(store)
}
