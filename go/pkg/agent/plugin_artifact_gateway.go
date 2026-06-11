package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	pluginArtifactHeaderAssignmentID = "X-ServiceRadar-Artifact-Assignment-Id"
	pluginArtifactHeaderPluginID     = "X-ServiceRadar-Artifact-Plugin-Id"
	pluginArtifactHeaderObjectKey    = "X-ServiceRadar-Artifact-Key"
	pluginArtifactHeaderSHA256       = "X-ServiceRadar-Artifact-Sha256"
	pluginArtifactHeaderSize         = "X-ServiceRadar-Artifact-Size"
	pluginArtifactHeaderSource       = "X-ServiceRadar-Artifact-Source"
)

var errGatewayArtifactUploadFailed = errors.New("gateway artifact upload failed")

type gatewayPluginArtifactUploader struct {
	httpClient *http.Client
	logger     logger.Logger
}

func newGatewayPluginArtifactUploader(security *models.SecurityConfig, log logger.Logger) (PluginArtifactUploader, error) {
	client, err := gatewayArtifactHTTPClient(security)
	if err != nil {
		return nil, err
	}

	return &gatewayPluginArtifactUploader{
		httpClient: client,
		logger:     log,
	}, nil
}

func (u *gatewayPluginArtifactUploader) UploadPluginArtifact(
	ctx context.Context,
	request PluginArtifactUploadRequest,
) (PluginArtifactUploadResponse, error) {
	if u == nil || u.httpClient == nil {
		return PluginArtifactUploadResponse{}, errPluginArtifactUploaderUnavailable
	}

	uploadURL, err := pluginArtifactUploadURL(request.DownloadURL)
	if err != nil {
		return PluginArtifactUploadResponse{}, err
	}

	file, err := os.Open(request.FilePath)
	if err != nil {
		return PluginArtifactUploadResponse{}, err
	}
	defer func() { _ = file.Close() }()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, uploadURL, file)
	if err != nil {
		return PluginArtifactUploadResponse{}, err
	}

	httpReq.Header.Set(pluginArtifactHeaderAssignmentID, request.AssignmentID)
	httpReq.Header.Set(pluginArtifactHeaderPluginID, request.PluginID)
	httpReq.Header.Set(pluginArtifactHeaderObjectKey, request.ObjectKey)
	httpReq.Header.Set(pluginArtifactHeaderSHA256, request.SHA256)
	httpReq.Header.Set(pluginArtifactHeaderSize, strconv.FormatInt(request.Size, 10))
	if strings.TrimSpace(request.Source) != "" {
		httpReq.Header.Set(pluginArtifactHeaderSource, request.Source)
	}
	if strings.TrimSpace(request.ContentType) != "" {
		httpReq.Header.Set("Content-Type", request.ContentType)
	}
	httpReq.ContentLength = request.Size

	resp, err := u.httpClient.Do(httpReq)
	if err != nil {
		return PluginArtifactUploadResponse{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return PluginArtifactUploadResponse{}, fmt.Errorf("%w: status %d", errGatewayArtifactUploadFailed, resp.StatusCode)
	}

	var uploadResponse PluginArtifactUploadResponse
	if err := json.NewDecoder(resp.Body).Decode(&uploadResponse); err != nil {
		return PluginArtifactUploadResponse{}, err
	}
	if uploadResponse.ObjectKey == "" {
		return PluginArtifactUploadResponse{}, errPluginArtifactUploaderUnavailable
	}

	return uploadResponse, nil
}
