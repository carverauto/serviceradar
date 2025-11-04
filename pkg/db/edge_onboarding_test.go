package db

import (
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildEdgeOnboardingPackagesQuery_WithFilters(t *testing.T) {
	packageID := uuid.New()
	filter := &models.EdgeOnboardingListFilter{
		PollerID:    "k8s-poller",
		ComponentID: "component-1",
		ParentID:    "parent-1",
		Statuses: []models.EdgeOnboardingStatus{
			models.EdgeOnboardingStatusIssued,
			models.EdgeOnboardingStatusDelivered,
		},
		Types: []models.EdgeOnboardingComponentType{
			models.EdgeOnboardingComponentTypePoller,
		},
		Limit: 25,
	}

	query, args := buildEdgeOnboardingPackagesQuery(edgeOnboardingQueryOptions{
		PackageID: &packageID,
		Filter:    filter,
	})

	require.Contains(t, query, "WITH filtered AS")
	require.Contains(t, query, "FROM table(edge_onboarding_packages)")
	require.Contains(t, query, "FROM filtered")
	require.Contains(t, query, "GROUP BY package_id")
	require.Contains(t, query, "ORDER BY latest_updated_at DESC")
	require.Contains(t, query, "LIMIT $")

	require.Len(t, args, 8)
	require.Equal(t, packageID, args[0])
	require.Equal(t, filter.PollerID, args[1])
	require.Equal(t, filter.ComponentID, args[2])
	require.Equal(t, filter.ParentID, args[3])
	require.Equal(t, string(filter.Types[0]), args[4])
	require.Equal(t, string(filter.Statuses[0]), args[5])
	require.Equal(t, string(filter.Statuses[1]), args[6])
	require.Equal(t, filter.Limit, args[7])
}

func TestBuildEdgeOnboardingPackagesQuery_DefaultLimit(t *testing.T) {
	query, args := buildEdgeOnboardingPackagesQuery(edgeOnboardingQueryOptions{})

	require.Contains(t, query, "FROM table(edge_onboarding_packages)")
	require.Contains(t, query, "LIMIT $1")
	require.Len(t, args, 1)
	require.Equal(t, defaultEdgeOnboardingPackageLimit, args[0])
}
