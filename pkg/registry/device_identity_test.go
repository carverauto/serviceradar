package registry

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

func TestDeviceIdentityResolver_IPFallbackWhenStrongUnknown(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()
	mockDB.EXPECT().
		ExecuteQuery(gomock.Any(), gomock.Any(), gomock.Any()).
		Return([]map[string]interface{}{}, nil).
		AnyTimes()

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), []string{"10.0.0.1"}, gomock.Nil()).
		Return([]*models.UnifiedDevice{
			{
				DeviceID: "sr:existing-1234",
				IP:       "10.0.0.1",
			},
		}, nil)

	resolver := NewDeviceIdentityResolver(mockDB, logger.NewTestLogger())

	updates := []*models.DeviceUpdate{
		{
			IP:        "10.0.0.1",
			DeviceID:  "",
			Partition: "default",
			Source:    models.DiscoverySourceArmis,
			Metadata: map[string]string{
				"armis_device_id": "armis-1",
			},
		},
	}

	err := resolver.ResolveDeviceIDs(ctx, updates)
	require.NoError(t, err)
	require.Len(t, updates, 1)

	assert.Equal(t, "sr:existing-1234", updates[0].DeviceID)
}
