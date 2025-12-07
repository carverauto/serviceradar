package registry

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"go.uber.org/mock/gomock"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

type cnpgMockService struct {
	*db.MockService
	useCNPG bool
	queryFn func(ctx context.Context, query string, args ...interface{}) (db.Rows, error)
}

var (
	errQueryFnNotConfigured = errors.New("query function not configured")
	errSliceRowsExhausted   = errors.New("no row available")
	errUnsupportedScanDest  = errors.New("unsupported scan destination")
)

func (m *cnpgMockService) UseCNPGReads() bool {
	return m.useCNPG
}

func (m *cnpgMockService) QueryRegistryRows(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
	if m.queryFn == nil {
		return nil, errQueryFnNotConfigured
	}
	return m.queryFn(ctx, query, args...)
}

type sliceRows struct {
	rows [][]string
	idx  int
	err  error
}

func (r *sliceRows) Next() bool {
	if r.idx >= len(r.rows) {
		return false
	}
	r.idx++
	return true
}

func (r *sliceRows) Scan(dest ...interface{}) error {
	if r.idx == 0 || r.idx > len(r.rows) {
		return errSliceRowsExhausted
	}

	values := r.rows[r.idx-1]
	for i, d := range dest {
		strPtr, ok := d.(*string)
		if !ok {
			return fmt.Errorf("%w: %T", errUnsupportedScanDest, d)
		}
		if i < len(values) {
			*strPtr = values[i]
		} else {
			*strPtr = ""
		}
	}
	return nil
}

func (r *sliceRows) Close() error {
	return nil
}

func (r *sliceRows) Err() error {
	return r.err
}

func TestResolveArmisIDsCNPG(t *testing.T) {
	ctrl := gomock.NewController(t)
	mockService := &cnpgMockService{
		MockService: db.NewMockService(ctrl),
		useCNPG:     true,
	}

	mockService.queryFn = func(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
		require.Contains(t, query, "metadata->>'armis_device_id'")
		require.Len(t, args, 1)
		values, ok := args[0].([]string)
		require.True(t, ok)
		assert.ElementsMatch(t, []string{"armis-1", "armis-2"}, values)

		return &sliceRows{
			rows: [][]string{
				{"armis-1", "device-1"},
				{"armis-2", "device-2"},
			},
		}, nil
	}

	registry := NewDeviceRegistry(mockService, logger.NewTestLogger())
	out := map[string]string{}

	err := registry.resolveArmisIDs(context.Background(), []string{"armis-1", "armis-2"}, out)
	require.NoError(t, err)
	assert.Equal(t, map[string]string{
		"armis-1": "device-1",
		"armis-2": "device-2",
	}, out)
}

func TestResolveIPsToCanonicalCNPG(t *testing.T) {
	ctrl := gomock.NewController(t)
	mockService := &cnpgMockService{
		MockService: db.NewMockService(ctrl),
		useCNPG:     true,
	}

	mockService.queryFn = func(ctx context.Context, query string, args ...interface{}) (db.Rows, error) {
		require.Contains(t, query, "DISTINCT ON (ip)")
		require.Len(t, args, 2)
		ipArgs, ok := args[0].([]string)
		require.True(t, ok)
		assert.ElementsMatch(t, []string{"10.0.0.1", "10.0.0.2"}, ipArgs)
		assert.Equal(t, integrationTypeNetbox, args[1])

		return &sliceRows{
			rows: [][]string{
				{"10.0.0.1", "device-a"},
				{"10.0.0.2", "device-b"},
			},
		}, nil
	}

	// Because resolveIPsToCanonical now calls resolveCanonicalIPMappings, we must expect a lookup.
	// We return them as valid canonical devices.
	mockService.MockService.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, ips []string, ids []string) ([]*models.UnifiedDevice, error) {
			var res []*models.UnifiedDevice
			for _, id := range ids {
				if id == "device-a" || id == "device-b" {
					res = append(res, &models.UnifiedDevice{
						DeviceID: id,
						Metadata: &models.DiscoveredField[map[string]string]{Value: map[string]string{}},
					})
				}
			}
			return res, nil
		}).AnyTimes()

	registry := NewDeviceRegistry(mockService, logger.NewTestLogger())
	out := map[string]string{}

	err := registry.resolveIPsToCanonical(context.Background(), []string{"10.0.0.1", "10.0.0.2"}, out)
	require.NoError(t, err)
	assert.Equal(t, map[string]string{
		"10.0.0.1": "device-a",
		"10.0.0.2": "device-b",
	}, out)
}

