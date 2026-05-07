package agentgateway

import (
	"context"
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
