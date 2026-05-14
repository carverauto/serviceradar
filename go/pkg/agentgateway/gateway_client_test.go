package agentgateway

import (
	"context"
	"errors"
	"testing"

	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func TestGetConfigTreatsSameVersionResponseAsNotModified(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockClient := proto.NewMockAgentGatewayServiceClient(ctrl)
	client := NewGatewayClient("gateway:50052", nil, logger.NewTestLogger())
	client.client = mockClient
	client.connected = true

	req := &proto.AgentConfigRequest{
		AgentId:       "agent-1",
		ConfigVersion: "vabc123",
	}

	mockClient.EXPECT().
		GetConfig(gomock.Any(), req).
		Return(&proto.AgentConfigResponse{
			NotModified:   false,
			ConfigVersion: "vabc123",
		}, nil)

	resp, err := client.GetConfig(context.Background(), req)
	if err != nil {
		t.Fatalf("GetConfig returned error: %v", err)
	}
	if !resp.NotModified {
		t.Fatal("expected same-version response to be marked not modified")
	}
}

func TestDesktopMediaMethodsFailWhenDisconnected(t *testing.T) {
	t.Parallel()

	client := NewGatewayClient("gateway:50052", nil, logger.NewTestLogger())
	ctx := context.Background()

	if _, err := client.OpenDesktopMediaSession(ctx, &proto.OpenDesktopMediaSessionRequest{}); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("OpenDesktopMediaSession error = %v, want %v", err, ErrGatewayNotConnected)
	}

	if _, err := client.StreamDesktopMedia(ctx); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("StreamDesktopMedia error = %v, want %v", err, ErrGatewayNotConnected)
	}

	if _, err := client.HeartbeatDesktopMediaSession(ctx, &proto.DesktopMediaHeartbeat{}); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("HeartbeatDesktopMediaSession error = %v, want %v", err, ErrGatewayNotConnected)
	}

	if _, err := client.CloseDesktopMediaSession(ctx, &proto.CloseDesktopMediaSessionRequest{}); !errors.Is(err, ErrGatewayNotConnected) {
		t.Fatalf("CloseDesktopMediaSession error = %v, want %v", err, ErrGatewayNotConnected)
	}
}
