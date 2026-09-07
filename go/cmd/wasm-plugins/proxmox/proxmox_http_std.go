//go:build !tinygo

package main

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func getJSON[T any](cfg Config, target Target, token, path string, out *T) error {
	resp, err := proxmoxHTTP.Do(sdk.HTTPRequest{
		Method:             http.MethodGet,
		URL:                strings.TrimRight(target.BaseURL, "/") + path,
		Headers:            map[string]string{"Authorization": token, "Accept": "application/json"},
		TimeoutMS:          cfg.TimeoutMS,
		InsecureSkipVerify: false,
	})
	if err != nil {
		return err
	}
	if resp.Status < 200 || resp.Status >= 300 {
		return fmt.Errorf("HTTP %d%s", resp.Status, responseBodySuffix(resp.Body))
	}
	if err := decodeProxmoxJSON(resp.Body, out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	return nil
}

func responseBodySuffix(body []byte) string {
	bodyText := strings.Join(strings.Fields(string(body)), " ")
	bodyText = sanitizeSecretString(bodyText)
	if bodyText == "" {
		return ""
	}
	bodyText = truncateString(bodyText, 300)

	return ": " + bodyText
}
