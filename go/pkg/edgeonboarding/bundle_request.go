package edgeonboarding

import (
	"context"
	"fmt"
	"net/http"
	"strings"
)

const downloadTokenHeader = "X-ServiceRadar-Download-Token"

func newBundleDownloadRequest(ctx context.Context, bundleURL, downloadToken string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, bundleURL, nil)
	if err != nil {
		return nil, fmt.Errorf("build bundle request: %w", err)
	}

	token := strings.TrimSpace(downloadToken)
	if token != "" {
		req.Header.Set(downloadTokenHeader, token)
	}

	return req, nil
}
