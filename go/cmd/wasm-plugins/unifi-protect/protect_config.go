package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func loadConfig() (Config, error) {
	raw, err := loadRawConfigBytes()
	if err != nil {
		return defaultConfig(), err
	}
	return decodeConfig(raw)
}

func (c Config) normalizedBootstrapPath() string {
	path := strings.TrimSpace(c.BootstrapPath)
	if path == "" {
		return "/proxy/protect/api/bootstrap"
	}
	if strings.HasPrefix(path, "/") {
		return path
	}
	return "/" + path
}

func (c Config) normalizedLoginPath() string {
	path := strings.TrimSpace(c.LoginPath)
	if path == "" {
		return "/api/auth/login"
	}
	if strings.HasPrefix(path, "/") {
		return path
	}
	return "/" + path
}

func (c Config) normalizedRTSPPort() int {
	if c.RTSPPort > 0 && c.RTSPPort <= 65535 {
		return c.RTSPPort
	}
	return 7447
}

func protectSessionHeaders(ctx context.Context, cfg Config, client protectHTTPClient) (map[string]string, string, error) {
	if strings.TrimSpace(cfg.APIKey) != "" {
		return map[string]string{"X-API-Key": strings.TrimSpace(cfg.APIKey)}, "api_key", nil
	}

	if strings.TrimSpace(cfg.Cookie) != "" {
		return map[string]string{"Cookie": strings.TrimSpace(cfg.Cookie)}, "cookie", nil
	}

	if strings.TrimSpace(cfg.Username) == "" && strings.TrimSpace(cfg.Password) == "" {
		return nil, "none", nil
	}

	body, err := json.Marshal(map[string]interface{}{
		"username":   cfg.Username,
		"password":   cfg.Password,
		"rememberMe": true,
	})
	if err != nil {
		return nil, "", err
	}

	resp, err := client.DoContext(ctx, sdk.HTTPRequest{
		Method: "POST",
		URL:    client.URL(cfg.normalizedLoginPath()),
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: body,
	})
	if err != nil {
		return nil, "", err
	}

	if resp.Status != http.StatusOK && resp.Status != http.StatusNoContent {
		return nil, "", fmt.Errorf("login failed with status %d", resp.Status)
	}

	setCookie := headerValue(resp.Headers, "Set-Cookie")
	cookie := extractSessionCookie(setCookie)
	if cookie == "" {
		return nil, "", fmt.Errorf("login response missing session cookie")
	}

	return map[string]string{"Cookie": cookie}, "session_cookie", nil
}
