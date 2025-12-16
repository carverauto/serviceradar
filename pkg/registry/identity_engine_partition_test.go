package registry

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestBatchLookupByStrongIdentifiers_PartitionScoped(t *testing.T) {
	ctrl := gomock.NewController(t)
	mockDB := db.NewMockService(ctrl)
	engine := NewIdentityEngine(mockDB, logger.NewTestLogger())

	mac := "AA:BB:CC:DD:EE:FF"
	normalizedMAC := NormalizeMAC(mac)

	updateA := &models.DeviceUpdate{Partition: "tenant-a", MAC: stringPtr(mac)}
	updateB := &models.DeviceUpdate{Partition: "tenant-b", MAC: stringPtr(mac)}

	updateIdentifiers := map[*models.DeviceUpdate]*StrongIdentifiers{
		updateA: engine.ExtractStrongIdentifiers(updateA),
		updateB: engine.ExtractStrongIdentifiers(updateB),
	}

	mockDB.EXPECT().
		BatchGetDeviceIDsByIdentifier(gomock.Any(), IdentifierTypeMAC, gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, identifierType string, identifierValues []string, partition string) (map[string]string, error) {
			require.Equal(t, IdentifierTypeMAC, identifierType)
			require.ElementsMatch(t, []string{normalizedMAC}, identifierValues)

			switch partition {
			case "tenant-a":
				return map[string]string{normalizedMAC: "sr:tenant-a-device-123"}, nil
			case "tenant-b":
				return map[string]string{normalizedMAC: "sr:tenant-b-device-456"}, nil
			default:
				return map[string]string{}, nil
			}
		}).
		Times(2)

	matches := engine.batchLookupByStrongIdentifiers(context.Background(), []*models.DeviceUpdate{updateA, updateB}, updateIdentifiers)

	require.Equal(t, "sr:tenant-a-device-123", matches[updateA])
	require.Equal(t, "sr:tenant-b-device-456", matches[updateB])
}
