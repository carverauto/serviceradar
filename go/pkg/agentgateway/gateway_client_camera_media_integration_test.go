package agentgateway

import (
	"context"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func TestGatewayClientCameraMediaLiveNegotiation(t *testing.T) {
	t.Parallel()

	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	gatewayAddr := os.Getenv("SERVICERADAR_CAMERA_GATEWAY_ADDR")
	certDir := os.Getenv("SERVICERADAR_CAMERA_GATEWAY_CERT_DIR")
	openLease := requireInt64Env(t, "SERVICERADAR_CAMERA_OPEN_LEASE_EXPIRES_AT_UNIX")
	heartbeatLease := requireInt64Env(t, "SERVICERADAR_CAMERA_HEARTBEAT_LEASE_EXPIRES_AT_UNIX")

	if gatewayAddr == "" || certDir == "" {
		t.Skip("skipping live camera media negotiation test; gateway address or cert dir not set")
	}

	client := NewGatewayClient(
		gatewayAddr,
		&models.SecurityConfig{
			Mode:       models.SecurityModeMTLS,
			CertDir:    certDir,
			ServerName: "localhost",
			Role:       models.RoleAgent,
			TLS: models.TLSConfig{
				CertFile: "client.pem",
				KeyFile:  "client-key.pem",
				CAFile:   "root.pem",
			},
		},
		logger.NewTestLogger(),
	)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx); err != nil {
		t.Fatalf("connect gateway client: %v", err)
	}

	t.Cleanup(func() {
		if err := client.Disconnect(); err != nil {
			t.Fatalf("disconnect gateway client: %v", err)
		}
	})

	openResp, err := client.OpenRelaySession(ctx, &proto.OpenRelaySessionRequest{
		RelaySessionId:  "relay-go-client-1",
		AgentId:         "agent-1",
		CameraSourceId:  "camera-1",
		StreamProfileId: "main",
		LeaseToken:      "lease-go-client-1",
		CodecHint:       "h264",
		ContainerHint:   "annexb",
	})
	if err != nil {
		t.Fatalf("open relay session: %v", err)
	}

	if !openResp.Accepted {
		t.Fatalf("expected accepted relay session")
	}
	if openResp.MediaIngestId == "" {
		t.Fatalf("expected non-empty media_ingest_id")
	}
	if openResp.MaxChunkBytes != 262144 {
		t.Fatalf("unexpected max_chunk_bytes: got %d", openResp.MaxChunkBytes)
	}
	if openResp.LeaseExpiresAtUnix != openLease {
		t.Fatalf("unexpected open lease expiry: got %d want %d", openResp.LeaseExpiresAtUnix, openLease)
	}

	uploadResp, err := client.UploadMedia(ctx, []*proto.MediaChunk{
		{
			RelaySessionId: "relay-go-client-1",
			MediaIngestId:  openResp.MediaIngestId,
			AgentId:        "agent-1",
			Sequence:       7,
			Payload:        []byte{1, 2, 3, 4},
			Codec:          "h264",
			PayloadFormat:  "annexb",
			TrackId:        "video",
		},
	})
	if err != nil {
		t.Fatalf("upload media: %v", err)
	}
	if !uploadResp.Received {
		t.Fatalf("expected upload acknowledged")
	}
	if uploadResp.LastSequence != 7 {
		t.Fatalf("unexpected upload sequence: got %d", uploadResp.LastSequence)
	}

	heartbeatResp, err := client.HeartbeatRelaySession(ctx, &proto.RelayHeartbeat{
		RelaySessionId: "relay-go-client-1",
		MediaIngestId:  openResp.MediaIngestId,
		AgentId:        "agent-1",
		LastSequence:   7,
		SentBytes:      4,
	})
	if err != nil {
		t.Fatalf("heartbeat relay session: %v", err)
	}
	if !heartbeatResp.Accepted {
		t.Fatalf("expected heartbeat accepted")
	}
	if heartbeatResp.LeaseExpiresAtUnix != heartbeatLease {
		t.Fatalf("unexpected heartbeat lease expiry: got %d want %d", heartbeatResp.LeaseExpiresAtUnix, heartbeatLease)
	}

	closeResp, err := client.CloseRelaySession(ctx, &proto.CloseRelaySessionRequest{
		RelaySessionId: "relay-go-client-1",
		MediaIngestId:  openResp.MediaIngestId,
		AgentId:        "agent-1",
		Reason:         "go integration close",
	})
	if err != nil {
		t.Fatalf("close relay session: %v", err)
	}
	if !closeResp.Closed {
		t.Fatalf("expected relay close acknowledged")
	}
}

func requireInt64Env(t *testing.T, key string) int64 {
	t.Helper()

	value := os.Getenv(key)
	if value == "" {
		t.Skipf("skipping live camera media negotiation test; %s is not set", key)
	}

	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		t.Fatalf("parse %s: %v", key, err)
	}

	return parsed
}
