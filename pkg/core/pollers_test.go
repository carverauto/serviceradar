package core

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestResolveServiceHostIPFallsBackToStoredStatus(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().
		GetPollerStatus(gomock.Any(), "poller-1").
		Return(&models.PollerStatus{HostIP: "10.0.0.5"}, nil)

	server := &Server{
		DB: mockDB,
	}

	ip := server.resolveServiceHostIP(ctx, "poller-1", "", "")

	require.Equal(t, "10.0.0.5", ip)
}
