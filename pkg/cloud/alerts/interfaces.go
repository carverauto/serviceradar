// Package alerts pkg/cloud/alerts/interfaces.go

//go:generate mockgen -destination=mock_alerts.go -package=alerts github.com/mfreeman451/serviceradar/pkg/cloud/alerts AlertService

package alerts

import (
	"context"
)

// AlertService defines the interface for alert implementations.
type AlertService interface {
	// Alert sends an alert through the service
	Alert(ctx context.Context, alert *WebhookAlert) error

	// IsEnabled returns whether the alerter is enabled
	IsEnabled() bool
}
