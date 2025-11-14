package edgeonboarding

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDownloadPackageSuccess(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/api/admin/edge-packages/pkg-123/download", r.URL.Path)
		require.Equal(t, "json", r.URL.Query().Get("format"))
		var req map[string]string
		require.NoError(t, json.NewDecoder(r.Body).Decode(&req))
		require.Equal(t, "token-xyz", req["download_token"])

		resp := deliverResponse{
			Package: edgePackagePayload{
				PackageID:              "pkg-123",
				Label:                  "Edge Poller",
				ComponentID:            "poller-a",
				ComponentType:          string(models.EdgeOnboardingComponentTypePoller),
				Status:                 string(models.EdgeOnboardingStatusDelivered),
				DownstreamSPIFFEID:     "spiffe://example.org/ns/edge/poller-a",
				JoinTokenExpiresAt:     time.Now().Add(time.Hour),
				DownloadTokenExpiresAt: time.Now().Add(2 * time.Hour),
				CreatedAt:              time.Now(),
				UpdatedAt:              time.Now(),
			},
			JoinToken: "join-json",
			BundlePEM: "bundle-json",
		}
		w.Header().Set("Content-Type", "application/json")
		require.NoError(t, json.NewEncoder(w).Encode(resp))
	}))
	defer server.Close()

	token, err := encodeTokenPayload(tokenPayload{
		PackageID:     "pkg-123",
		DownloadToken: "token-xyz",
		CoreURL:       server.URL,
	})
	require.NoError(t, err)

	b, err := NewBootstrapper(&Config{
		Token:       token,
		KVEndpoint:  "kv:50057",
		ServiceType: models.EdgeOnboardingComponentTypePoller,
	})
	require.NoError(t, err)

	require.NoError(t, b.downloadPackage(context.Background()))
	require.NotNil(t, b.pkg)
	require.Equal(t, "pkg-123", b.pkg.PackageID)
	require.Equal(t, "poller-a", b.pkg.ComponentID)
	require.Equal(t, "spiffe://example.org/ns/edge/poller-a", b.pkg.DownstreamSPIFFEID)
	require.NotNil(t, b.downloadResult)
	require.Equal(t, "join-json", b.downloadResult.JoinToken)
	require.Equal(t, "bundle-json", string(b.downloadResult.BundlePEM))
}

func TestDownloadPackageFromArchive(t *testing.T) {
	now := time.Now().UTC()
	meta := &archiveMetadataFile{
		PackageID:          "pkg-archive",
		Label:              "Offline Poller",
		ComponentID:        "poller-offline",
		ComponentType:      string(models.EdgeOnboardingComponentTypePoller),
		PollerID:           "poller-offline",
		Status:             string(models.EdgeOnboardingStatusDelivered),
		DownstreamSPIFFEID: "spiffe://example.org/ns/edge/offline",
		Selectors:          []string{"unix:uid:0"},
		JoinTokenExpiresAt: now.Add(30 * time.Minute),
		DownloadExpiresAt:  now.Add(2 * time.Hour),
		CreatedAt:          now,
		UpdatedAt:          now,
		Metadata: map[string]interface{}{
			"core_address":           "core:50052",
			"kv_address":             "kv:50057",
			"datasvc_endpoint":       "kv:50057",
			"spire_upstream_address": "spire-server:8081",
		},
	}
	archivePath := writeTestArchive(t, meta, "offline-token\n", "offline-bundle\n")

	b, err := NewBootstrapper(&Config{
		PackagePath: archivePath,
		KVEndpoint:  "kv:50057",
		ServiceType: models.EdgeOnboardingComponentTypePoller,
	})
	require.NoError(t, err)

	require.NoError(t, b.downloadPackage(context.Background()))
	require.NotNil(t, b.pkg)
	require.Equal(t, "pkg-archive", b.pkg.PackageID)
	require.Equal(t, "poller-offline", b.pkg.ComponentID)
	require.Equal(t, "spiffe://example.org/ns/edge/offline", b.pkg.DownstreamSPIFFEID)
	require.NotNil(t, b.downloadResult)
	require.Equal(t, "offline-token", b.downloadResult.JoinToken)
	require.Equal(t, "offline-bundle\n", string(b.downloadResult.BundlePEM))
}

func writeTestArchive(t *testing.T, meta *archiveMetadataFile, joinToken, bundle string) string {
	t.Helper()

	dir := t.TempDir()
	path := filepath.Join(dir, "edge-package.tar.gz")

	file, err := os.Create(path)
	require.NoError(t, err)
	defer func() { _ = file.Close() }()

	gzw := gzip.NewWriter(file)
	defer func() { _ = gzw.Close() }()

	tw := tar.NewWriter(gzw)
	defer func() { _ = tw.Close() }()

	metaBytes, err := json.Marshal(meta)
	require.NoError(t, err)

	writeArchiveFile(t, tw, "metadata.json", metaBytes)
	writeArchiveFile(t, tw, "spire/upstream-join-token", []byte(joinToken))
	writeArchiveFile(t, tw, "spire/upstream-bundle.pem", []byte(bundle))

	return path
}

func writeArchiveFile(t *testing.T, tw *tar.Writer, name string, body []byte) {
	t.Helper()
	if strings.HasSuffix(name, "/") {
		hdr := &tar.Header{
			Name:     name,
			Typeflag: tar.TypeDir,
			Mode:     0o755,
			ModTime:  time.Now(),
		}
		require.NoError(t, tw.WriteHeader(hdr))
		return
	}
	hdr := &tar.Header{
		Name:    name,
		Size:    int64(len(body)),
		Mode:    0o600,
		ModTime: time.Now(),
	}
	require.NoError(t, tw.WriteHeader(hdr))
	if len(body) > 0 {
		_, err := tw.Write(body)
		require.NoError(t, err)
	}
}
