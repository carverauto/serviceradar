package registry

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestPromotionStatus_Disabled(t *testing.T) {
	r := &DeviceRegistry{}
	now := time.Now()

	status := r.promotionStatusForSighting(now, &models.NetworkSighting{})
	require.NotNil(t, status)
	require.False(t, status.Eligible)
	require.Contains(t, status.Blockers, "identity reconciliation disabled")
}

func TestPromotionStatus_PersistenceBlocked(t *testing.T) {
	cfg := &models.IdentityReconciliationConfig{
		Enabled: true,
		Promotion: models.PromotionConfig{
			Enabled:        true,
			MinPersistence: models.Duration(time.Hour),
		},
	}
	r := &DeviceRegistry{identityCfg: cfg}
	now := time.Now()
	firstSeen := now.Add(-30 * time.Minute)

	status := r.promotionStatusForSighting(now, &models.NetworkSighting{
		FirstSeen: firstSeen,
		Metadata:  map[string]string{},
	})

	require.False(t, status.MeetsPolicy)
	require.False(t, status.Eligible)
	require.NotNil(t, status.NextEligibleAt)
	require.True(t, status.NextEligibleAt.After(now))
	require.True(t, containsHint(status.Blockers, "persistence"))
}

func TestPromotionStatus_AutoPromotionDisabled(t *testing.T) {
	cfg := &models.IdentityReconciliationConfig{
		Enabled: true,
		Promotion: models.PromotionConfig{
			Enabled:        false,
			MinPersistence: models.Duration(time.Minute),
		},
	}
	r := &DeviceRegistry{identityCfg: cfg}
	now := time.Now()

	status := r.promotionStatusForSighting(now, &models.NetworkSighting{
		FirstSeen: now.Add(-2 * time.Minute),
		Metadata:  map[string]string{},
	})

	require.True(t, status.MeetsPolicy)
	require.False(t, status.Eligible)
	require.Contains(t, status.Blockers, "auto-promotion disabled")
}

func TestPromotionStatus_ShadowMode(t *testing.T) {
	cfg := &models.IdentityReconciliationConfig{
		Enabled: true,
		Promotion: models.PromotionConfig{
			Enabled:        true,
			ShadowMode:     true,
			MinPersistence: models.Duration(time.Minute),
		},
	}
	r := &DeviceRegistry{identityCfg: cfg}
	now := time.Now()

	status := r.promotionStatusForSighting(now, &models.NetworkSighting{
		FirstSeen: now.Add(-2 * time.Minute),
		Metadata:  map[string]string{},
	})

	require.True(t, status.MeetsPolicy)
	require.False(t, status.Eligible)
	require.True(t, status.ShadowMode)
	require.True(t, containsHint(status.Blockers, "shadow mode enabled"))
}

func TestPromotionStatus_Eligible(t *testing.T) {
	cfg := &models.IdentityReconciliationConfig{
		Enabled: true,
		Promotion: models.PromotionConfig{
			Enabled:        true,
			MinPersistence: models.Duration(30 * time.Minute),
		},
	}
	r := &DeviceRegistry{identityCfg: cfg}
	now := time.Now()

	status := r.promotionStatusForSighting(now, &models.NetworkSighting{
		FirstSeen: now.Add(-1 * time.Hour),
		Metadata: map[string]string{
			"hostname": "example-host",
		},
	})

	require.True(t, status.MeetsPolicy)
	require.True(t, status.Eligible)
	require.False(t, status.ShadowMode)
	require.Nil(t, status.Blockers)
	require.Nil(t, status.NextEligibleAt)
}

func containsHint(hints []string, needle string) bool {
	for _, hint := range hints {
		if strings.Contains(hint, needle) {
			return true
		}
	}
	return false
}
